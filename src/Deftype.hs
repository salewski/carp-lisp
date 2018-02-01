module Deftype (moduleForDeftype, bindingsForRegisteredType) where

import qualified Data.Map as Map
import Data.Maybe
import Debug.Trace

import Obj
import Types
import Util
import Template
import Infer
import Concretize
import Polymorphism
import ArrayTemplates

data AllocationMode = StackAlloc | HeapAlloc

{-# ANN module "HLint: ignore Reduce duplication" #-}
-- | This function creates a "Type Module" with the same name as the type being defined.
--   A type module provides a namespace for all the functions that area automatically
--   generated by a deftype.
moduleForDeftype :: TypeEnv -> Env -> [String] -> String -> [Ty] -> [XObj] -> Maybe Info -> Either String (String, XObj, [XObj])
moduleForDeftype typeEnv env pathStrings typeName typeVariables rest i =
  let typeModuleName = typeName
      emptyTypeModuleEnv = Env (Map.fromList []) (Just env) (Just typeModuleName) [] ExternalEnv
      -- The variable 'insidePath' is the path used for all member functions inside the 'typeModule'.
      -- For example (module Vec2 [x Float]) creates bindings like Vec2.create, Vec2.x, etc.
      insidePath = pathStrings ++ [typeModuleName]
  in case validateMembers typeEnv typeVariables rest of
       Left err ->
         Left err
       Right _ ->
         case
           do let structTy = StructTy typeName typeVariables
              okInit <- templateForInit insidePath structTy rest
              --okNew <- templateForNew insidePath structTy rest
              (okStr, strDeps) <- templateForStr typeEnv env insidePath structTy rest
              (okDelete, deleteDeps) <- templateForDelete typeEnv env insidePath structTy rest
              (okCopy, copyDeps) <- templateForCopy typeEnv env insidePath structTy rest
              (okMembers, membersDeps) <- templatesForMembers typeEnv env insidePath structTy rest
              let funcs = okInit  : okStr : okDelete : okCopy : okMembers
                  moduleEnvWithBindings = addListOfBindings emptyTypeModuleEnv funcs
                  typeModuleXObj = XObj (Mod moduleEnvWithBindings) i (Just ModuleTy)
                  deps = deleteDeps ++ membersDeps ++ copyDeps ++ strDeps
              return (typeModuleName, typeModuleXObj, deps)
         of
           Just x -> Right x
           Nothing -> Left "Something's wrong with the templates..." -- TODO: Better messages here, should come from the template functions!

{-# ANN validateMembers "HLint: ignore Eta reduce" #-}
-- | Make sure that the member declarations in a type definition
-- | Follow the pattern [<name> <type>, <name> <type>, ...]
-- | TODO: What a mess this function is, clean it up!
validateMembers :: TypeEnv -> [Ty] -> [XObj] -> Either String ()
validateMembers typeEnv typeVariables rest = mapM_ validateOneCase rest
  where
    validateOneCase :: XObj -> Either String ()
    validateOneCase (XObj (Arr arr) _ _) =
      if length arr `mod` 2 == 0
      then mapM_ (okXObjForType . snd) (pairwise arr)
      else Left "Uneven nr of members / types."
    validateOneCase XObj {} =
      Left "Type members must be defined using array syntax: [member1 type1 member2 type2 ...]"

    okXObjForType :: XObj -> Either String ()
    okXObjForType xobj =
      case xobjToTy xobj of
        Just t -> okMemberType t
        Nothing -> Left ("Can't interpret this as a type: " ++ pretty xobj)

    okMemberType :: Ty -> Either String ()
    okMemberType t = case t of
                       IntTy    -> return ()
                       FloatTy  -> return ()
                       DoubleTy -> return ()
                       LongTy   -> return ()
                       BoolTy   -> return ()
                       StringTy -> return ()
                       CharTy   -> return ()
                       PointerTy inner -> do _ <- okMemberType inner
                                             return ()
                       StructTy "Array" [inner] -> do _ <- okMemberType inner
                                                      return ()
                       StructTy name tyVars ->
                         case lookupInEnv (SymPath [] name) (getTypeEnv typeEnv) of
                           Just _ -> return ()
                           Nothing -> Left ("Can't find '" ++ name ++ "' among registered types.")
                       VarTy _ -> if t `elem` typeVariables
                                  then return ()
                                  else Left ("Invalid type variable as member type: " ++ show t)
                       _ -> Left ("Invalid member type: " ++ show t)

-- | Helper function to create the binder for the 'str' template.
templateForStr :: TypeEnv -> Env -> [String] -> Ty -> [XObj] -> Maybe ((String, Binder), [XObj])
templateForStr typeEnv env insidePath structTy@(StructTy typeName _) [XObj (Arr membersXObjs) _ _] =
  if typeIsGeneric structTy
  then Just (templateGenericStr insidePath structTy membersXObjs, [])
  else Just (instanceBinderWithDeps (SymPath insidePath "str")
              (FuncTy [RefTy structTy] StringTy)
              (templateStr typeEnv env structTy (memberXObjsToPairs membersXObjs)))
templateForStr _ _ _ _ _ = Nothing

-- | Generate a list of types from a deftype declaration.
initArgListTypes :: [XObj] -> [Ty]
initArgListTypes xobjs = map (\(_, x) -> fromJust (xobjToTy x)) (pairwise xobjs)

-- | Helper function to create the binder for the 'copy' template.
templateForCopy :: TypeEnv -> Env -> [String] -> Ty -> [XObj] -> Maybe ((String, Binder), [XObj])
templateForCopy typeEnv env insidePath structTy@(StructTy typeName _) [XObj (Arr membersXObjs) _ _] =
  if typeIsGeneric structTy
  then Just (templateGenericCopy insidePath structTy membersXObjs, [])
  else Just (instanceBinderWithDeps (SymPath insidePath "copy")
              (FuncTy [RefTy structTy] structTy)
              (templateCopy typeEnv env (memberXObjsToPairs membersXObjs)))
templateForCopy _ _ _ _ _ = Nothing

-- | Generate all the templates for ALL the member variables in a deftype declaration.
templatesForMembers :: TypeEnv -> Env -> [String] -> Ty -> [XObj] -> Maybe ([(String, Binder)], [XObj])
templatesForMembers typeEnv env insidePath structTy [XObj (Arr membersXobjs) _ _] =
  let bindersAndDeps = concatMap (templatesForSingleMember typeEnv env insidePath structTy) (pairwise membersXobjs)
  in  Just (map fst bindersAndDeps, concatMap snd bindersAndDeps)
templatesForMembers _ _ _ _ _ = error "Can't create member functions for type with more than one case (yet)."

-- | Generate the templates for a single member in a deftype declaration.
templatesForSingleMember :: TypeEnv -> Env -> [String] -> Ty -> (XObj, XObj) -> [((String, Binder), [XObj])]
templatesForSingleMember typeEnv env insidePath p@(StructTy typeName _) (nameXObj, typeXObj) =
  let Just t = xobjToTy typeXObj
      memberName = getName nameXObj
  in [instanceBinderWithDeps (SymPath insidePath memberName) (FuncTy [RefTy p] (RefTy t)) (templateGetter (mangle memberName) (RefTy t))
     , if typeIsGeneric t
       then (templateGenericSetter insidePath p t memberName, [])
       else instanceBinderWithDeps (SymPath insidePath ("set-" ++ memberName)) (FuncTy [p, t] p) (templateSetter typeEnv env (mangle memberName) t)
     ,instanceBinderWithDeps (SymPath insidePath ("set-" ++ memberName ++ "!")) (FuncTy [RefTy (p), t] UnitTy) (templateSetterRef typeEnv env (mangle memberName) t)
     ,instanceBinderWithDeps (SymPath insidePath ("update-" ++ memberName))
                                                            (FuncTy [p, FuncTy [t] t] p)
                                                            (templateUpdater (mangle memberName))]

-- | Helper function to create the binder for the 'copy' template.
templateForInit :: [String] -> Ty -> [XObj] -> Maybe (String, Binder)
templateForInit insidePath structTy@(StructTy typeName _) [XObj (Arr membersXObjs) _ _] =
  if typeIsGeneric structTy
  then Just (templateGenericInit StackAlloc insidePath structTy membersXObjs)
  else Just $ instanceBinder (SymPath insidePath "init")
                (FuncTy (initArgListTypes membersXObjs) structTy)
                (templateInit StackAlloc structTy membersXObjs)
templateForInit _ _ _ = Nothing

-- | The template for the 'init' and 'new' functions for a deftype.
templateInit :: AllocationMode -> Ty -> [XObj] -> Template
templateInit allocationMode originalStructTy@(StructTy typeName typeVariables) memberXObjs =
  Template
    (FuncTy (map snd (memberXObjsToPairs memberXObjs)) (VarTy "p"))
    (\(FuncTy _ concreteStructTy) ->
     let mappings = unifySignatures originalStructTy concreteStructTy
         correctedMembers = replaceGenericTypeSymbolsOnMembers mappings memberXObjs
         memberPairs = memberXObjsToPairs correctedMembers
     in  (toTemplate $ "$p $NAME(" ++ joinWithComma (map memberArg memberPairs) ++ ")"))
    (const (toTemplate $ unlines [ "$DECL {"
                                 , case allocationMode of
                                     StackAlloc -> "    $p instance;"
                                     HeapAlloc ->  "    $p instance = CARP_MALLOC(sizeof(" ++ typeName ++ "));"
                                 , joinWith "\n" (map (memberAssignment allocationMode) (memberXObjsToPairs memberXObjs))
                                 , "    return instance;"
                                 , "}"]))
    (\(FuncTy _ _) -> [])
    -- (\(FuncTy _ concreteStructTy) ->
    --    instantiateGenericStructType (unifySignatures originalStructTy concreteStructTy) concreteStructTy memberXObjs)

templateGenericInit :: AllocationMode -> [String] -> Ty -> [XObj] -> (String, Binder)
templateGenericInit allocationMode pathStrings originalStructTy@(StructTy typeName _) membersXObjs =
  defineTypeParameterizedTemplate templateCreator path t
  where path = SymPath pathStrings "init"
        t = (FuncTy (map snd (memberXObjsToPairs membersXObjs)) originalStructTy)
        templateCreator = TemplateCreator $
          \typeEnv env ->
            Template
            (FuncTy (map snd (memberXObjsToPairs membersXObjs)) (VarTy "p"))
            (\(FuncTy _ concreteStructTy) ->
               let mappings = unifySignatures originalStructTy concreteStructTy
                   correctedMembers = replaceGenericTypeSymbolsOnMembers mappings membersXObjs
                   memberPairs = memberXObjsToPairs correctedMembers
               in  (toTemplate $ "$p $NAME(" ++ joinWithComma (map memberArg memberPairs) ++ ")"))
            (\(FuncTy _ _) ->
               (toTemplate $ unlines [ "$DECL {"
                                     , case allocationMode of
                                         StackAlloc -> "    $p instance;"
                                         HeapAlloc ->  "    $p instance = CARP_MALLOC(sizeof(" ++ typeName ++ "));"
                                     , joinWith "\n" (map (memberAssignment allocationMode) (memberXObjsToPairs membersXObjs))
                                     , "    return instance;"
                                     , "}"]))
            (\(FuncTy _ concreteStructTy) ->
               instantiateGenericType typeEnv concreteStructTy)




-- | The template for the 'str' function for a deftype.
templateStr :: TypeEnv -> Env -> Ty -> [(String, Ty)] -> Template
templateStr typeEnv env t@(StructTy typeName _) members =
  Template
    (FuncTy [RefTy t] StringTy)
    (\(FuncTy [RefTy structTy] StringTy) -> (toTemplate $ "string $NAME(" ++ tyToC structTy ++ " *p)"))
    (\(FuncTy [RefTy structTy@(StructTy _ concreteMemberTys)] StringTy) ->
        (toTemplate $ unlines [ "$DECL {"
                                , "  // convert members to string here:"
                                , "  string temp = NULL;"
                                , "  int tempsize = 0;"
                                , "  (void)tempsize; // that way we remove the occasional unused warning "
                                , calculateStructStrSize typeEnv env members structTy
                                , "  string buffer = CARP_MALLOC(size);"
                                , "  string bufferPtr = buffer;"
                                , ""
                                , "  snprintf(bufferPtr, size, \"(%s \", \"" ++ typeName ++ "\");"
                                , "  bufferPtr += strlen(\"" ++ typeName ++ "\") + 2;\n"
                                , "  // Concrete member tys: " ++ show concreteMemberTys
                                , joinWith "\n" (map (memberStr typeEnv env) members)
                                , "  bufferPtr--;"
                                , "  snprintf(bufferPtr, size, \")\");"
                                , "  return buffer;"
                                , "}"]))
    (\(ft@(FuncTy [RefTy structTy@(StructTy _ concreteMemberTys)] StringTy)) ->
       concatMap (depsOfPolymorphicFunction typeEnv env [] "str" . typesStrFunctionType typeEnv)
                 (filter (\t -> (not . isExternalType typeEnv) t && (not . isFullyGenericType) t)
                  (map snd members))
       ++
       (if typeIsGeneric structTy then [] else [defineFunctionTypeAlias ft])
    )

calculateStructStrSize :: TypeEnv -> Env -> [(String, Ty)] -> Ty -> String
calculateStructStrSize typeEnv env members structTy@(StructTy name _) =
  "  int size = snprintf(NULL, 0, \"(%s )\", \"" ++ name ++ "\");\n" ++
    unlines (map memberStrSize members)
  where memberStrSize (memberName, memberTy) =
          let refOrNotRefType = if isManaged typeEnv memberTy then RefTy memberTy else memberTy
              maybeTakeAddress = if isManaged typeEnv memberTy then "&" else ""
              strFuncType = FuncTy [refOrNotRefType] StringTy
           in case nameOfPolymorphicFunction typeEnv env strFuncType "str" of
                Just strFunctionPath ->
                  unlines ["  temp = " ++ pathToC strFunctionPath ++ "(" ++ maybeTakeAddress ++ "p->" ++ memberName ++ ");"
                          , "  size += snprintf(NULL, 0, \"%s \", temp);"
                          , "  if(temp) { CARP_FREE(temp); temp = NULL; }"
                          ]
                Nothing ->
                  if isExternalType typeEnv memberTy
                  then unlines [ "  size +=  snprintf(NULL, 0, \"%p \", p->" ++ memberName ++ ");"
                               , "  if(temp) { CARP_FREE(temp); temp = NULL; }"
                               ]
                  else "  // Failed to find str function for " ++ memberName ++ " : " ++ show memberTy ++ "\n"

templateGenericStr :: [String] -> Ty -> [XObj] -> (String, Binder)
templateGenericStr pathStrings originalStructTy@(StructTy typeName varTys) membersXObjs =
  defineTypeParameterizedTemplate templateCreator path t
  where path = SymPath pathStrings "str"
        t = FuncTy [(RefTy originalStructTy)] StringTy
        members = memberXObjsToPairs membersXObjs
        templateCreator = TemplateCreator $
          \typeEnv env ->
            Template
            t
            (\(FuncTy [RefTy concreteStructTy] StringTy) ->
               (toTemplate $ "string $NAME(" ++ tyToC concreteStructTy ++ " *p)"))
            (\(FuncTy [RefTy concreteStructTy@(StructTy _ concreteMemberTys)] StringTy) ->
               let mappings = unifySignatures originalStructTy concreteStructTy
                   correctedMembers = replaceGenericTypeSymbolsOnMembers mappings membersXObjs
                   memberPairs = memberXObjsToPairs correctedMembers
               in (toTemplate $ unlines [ "$DECL {"
                                        , "  // convert members to string here:"
                                        , "  string temp = NULL;"
                                        , "  int tempsize = 0;"
                                        , "  (void)tempsize; // that way we remove the occasional unused warning "
                                        , calculateStructStrSize typeEnv env memberPairs concreteStructTy
                                        , "  string buffer = CARP_MALLOC(size);"
                                        , "  string bufferPtr = buffer;"
                                        , ""
                                        , "  snprintf(bufferPtr, size, \"(%s \", \"" ++ typeName ++ "\");"
                                        , "  bufferPtr += strlen(\"" ++ typeName ++ "\") + 2;\n"
                                        , "  // Concrete member tys: " ++ show concreteMemberTys
                                        , joinWith "\n" (map (memberStr typeEnv env) memberPairs)
                                        , "  bufferPtr--;"
                                        , "  snprintf(bufferPtr, size, \")\");"
                                        , "  return buffer;"
                                        , "}"]))
            (\(ft@(FuncTy [RefTy concreteStructTy@(StructTy _ concreteMemberTys)] StringTy)) ->
               let mappings = unifySignatures originalStructTy concreteStructTy
                   correctedMembers = replaceGenericTypeSymbolsOnMembers mappings membersXObjs
                   memberPairs = memberXObjsToPairs correctedMembers
               in  concatMap (depsOfPolymorphicFunction typeEnv env [] "str" . typesStrFunctionType typeEnv)
                   (filter (\t -> (not . isExternalType typeEnv) t && (not . isFullyGenericType) t)
                    (map snd memberPairs))
                   ++
                   (if typeIsGeneric concreteStructTy then [] else [defineFunctionTypeAlias ft])
            )



-- | Generate C code for converting a member variable to a string and appending it to a buffer.
memberStr :: TypeEnv -> Env -> (String, Ty) -> String
memberStr typeEnv env (memberName, memberTy) =
  let refOrNotRefType = if isManaged typeEnv memberTy then RefTy memberTy else memberTy
      maybeTakeAddress = if isManaged typeEnv memberTy then "&" else ""
      strFuncType = FuncTy [refOrNotRefType] StringTy
   in case nameOfPolymorphicFunction typeEnv env strFuncType "str" of
        Just strFunctionPath ->
          unlines ["  temp = " ++ pathToC strFunctionPath ++ "(" ++ maybeTakeAddress ++ "p->" ++ memberName ++ ");"
                  , "  snprintf(bufferPtr, size, \"%s \", temp);"
                  , "  bufferPtr += strlen(temp) + 1;"
                  , "  if(temp) { CARP_FREE(temp); temp = NULL; }"
                  ]
        Nothing ->
          if isExternalType typeEnv memberTy
          then unlines [ "  tempsize = snprintf(NULL, 0, \"%p\", p->" ++ memberName ++ ");"
                       , "  temp = malloc(tempsize);"
                       , "  snprintf(temp, tempsize, \"%p\", p->" ++ memberName ++ ");"
                       , "  snprintf(bufferPtr, size, \"%s \", temp);"
                       , "  bufferPtr += strlen(temp) + 1;"
                       , "  if(temp) { CARP_FREE(temp); temp = NULL; }"
                       ]
          else "  // Failed to find str function for " ++ memberName ++ " : " ++ show memberTy ++ "\n"

-- | Creates the C code for an arg to the init function.
-- | i.e. "(deftype A [x Int])" will generate "int x" which
-- | will be used in the init function like this: "A_init(int x)"
memberArg :: (String, Ty) -> String
memberArg (memberName, memberTy) =
  templitizeTy memberTy ++ " " ++ memberName

-- | Generate C code for assigning to a member variable.
-- | Needs to know if the instance is a pointer or stack variable.
memberAssignment :: AllocationMode -> (String, Ty) -> String
memberAssignment allocationMode (memberName, _) = "    instance" ++ sep ++ memberName ++ " = " ++ memberName ++ ";"
  where sep = case allocationMode of
                StackAlloc -> "."
                HeapAlloc -> "->"

-- | The template for getters of a deftype.
templateGetter :: String -> Ty -> Template
templateGetter member fixedMemberTy =
  Template
    (FuncTy [RefTy (VarTy "p")] (VarTy "t"))
    (const (toTemplate "$t $NAME($(Ref p) p)"))
    (const (toTemplate ("$DECL { return &(p->" ++ member ++ "); }\n")))
    (const [])

-- | The template for setters of a deftype.
templateSetter :: TypeEnv -> Env -> String -> Ty -> Template
templateSetter typeEnv env memberName memberTy =
  let callToDelete = memberDeletion typeEnv env (memberName, memberTy)
  in
  Template
    (FuncTy [VarTy "p", VarTy "t"] (VarTy "p"))
    (const (toTemplate "$p $NAME($p p, $t newValue)"))
    (const (toTemplate (unlines ["$DECL {"
                                ,callToDelete
                                ,"    p." ++ memberName ++ " = newValue;"
                                ,"    return p;"
                                ,"}\n"])))
    (\_ -> if isManaged typeEnv memberTy
           then depsOfPolymorphicFunction typeEnv env [] "delete" (typesDeleterFunctionType memberTy)
           else [])

templateGenericSetter :: [String] -> Ty -> Ty -> String -> (String, Binder)
templateGenericSetter pathStrings originalStructTy memberTy memberName =
  defineTypeParameterizedTemplate templateCreator path (FuncTy [originalStructTy, memberTy] originalStructTy)
  where path = SymPath pathStrings ("set-" ++ memberName)
        t = (FuncTy [VarTy "p", VarTy "t"] (VarTy "p"))
        templateCreator = TemplateCreator $
          \typeEnv env ->
            Template
            t
            (const (toTemplate "$p $NAME($p p, $t newValue)"))
            (\(FuncTy [_, memberTy] _) ->
               (let callToDelete = memberDeletion typeEnv env (memberName, memberTy)
                in  (toTemplate (unlines ["$DECL {"
                                         ,callToDelete
                                         ,"    p." ++ memberName ++ " = newValue;"
                                         ,"    return p;"
                                         ,"}\n"]))))
            (\(FuncTy [_, memberTy] _) ->
               if isManaged typeEnv memberTy
               then depsOfPolymorphicFunction typeEnv env [] "delete" (typesDeleterFunctionType memberTy)
               else [])


-- | The template for setters of a deftype.
templateSetterRef :: TypeEnv -> Env -> String -> Ty -> Template
templateSetterRef typeEnv env memberName memberTy =
  Template
    (FuncTy [RefTy (VarTy "p"), VarTy "t"] UnitTy)
    (const (toTemplate "void $NAME($p* pRef, $t newValue)"))
    (const (toTemplate (unlines ["$DECL {"
                                ,"    pRef->" ++ memberName ++ " = newValue;"
                                ,"}\n"])))
    (\_ -> if isManaged typeEnv memberTy
           then depsOfPolymorphicFunction typeEnv env [] "delete" (typesDeleterFunctionType memberTy)
           else [])


-- | The template for updater functions of a deftype
-- | (allows changing a variable by passing an transformation function).
templateUpdater :: String -> Template
templateUpdater member =
  Template
    (FuncTy [VarTy "p", FuncTy [VarTy "t"] (VarTy "t")] (VarTy "p"))
    (const (toTemplate "$p $NAME($p p, $(Fn [t] t) updater)"))
    (const (toTemplate (unlines ["$DECL {"
                                ,"    p." ++ member ++ " = updater(p." ++ member ++ ");"
                                ,"    return p;"
                                ,"}\n"])))
    (\(FuncTy [_, t@(FuncTy [_] fRetTy)] _) ->
       if typeIsGeneric fRetTy
       then []
       else [defineFunctionTypeAlias t])

-- | Helper function to create the binder for the 'delete' template.
templateForDelete :: TypeEnv -> Env -> [String] -> Ty -> [XObj] -> Maybe ((String, Binder), [XObj])
templateForDelete typeEnv env insidePath structTy@(StructTy typeName _) [XObj (Arr membersXObjs) _ _] =
  if typeIsGeneric structTy
  then Just (templateGenericDelete insidePath structTy membersXObjs, [])
  else Just (instanceBinderWithDeps (SymPath insidePath "delete")
             (FuncTy [structTy] UnitTy)
             (templateDelete typeEnv env (memberXObjsToPairs membersXObjs)))
templateForDelete _ _ _ _ _ = Nothing

-- | The template for the 'delete' function of a deftype.
templateDelete :: TypeEnv -> Env -> [(String, Ty)] -> Template
templateDelete typeEnv env members =
  Template
   (FuncTy [VarTy "p"] UnitTy)
   (const (toTemplate "void $NAME($p p)"))
   (const (toTemplate $ unlines [ "$DECL {"
                                , joinWith "\n" (map (memberDeletion typeEnv env) members)
                                , "}"]))
   (\_ -> concatMap (depsOfPolymorphicFunction typeEnv env [] "delete" . typesDeleterFunctionType)
                    (filter (isManaged typeEnv) (map snd members)))

templateGenericDelete :: [String] -> Ty -> [XObj] -> (String, Binder)
templateGenericDelete pathStrings originalStructTy membersXObjs =
  defineTypeParameterizedTemplate templateCreator path (FuncTy [originalStructTy] UnitTy)
  where path = SymPath pathStrings "delete"
        t = (FuncTy [VarTy "p"] UnitTy)
        templateCreator = TemplateCreator $
          \typeEnv env ->
            Template
            t
            (const (toTemplate "void $NAME($p p)"))
            (\(FuncTy [concreteStructTy] UnitTy) ->
               let mappings = unifySignatures originalStructTy concreteStructTy
                   correctedMembers = replaceGenericTypeSymbolsOnMembers mappings membersXObjs
                   memberPairs = memberXObjsToPairs correctedMembers
               in  (toTemplate $ unlines [ "$DECL {"
                                         , joinWith "\n" (map (memberDeletion typeEnv env) memberPairs)
                                         , "}"]))
            (\(FuncTy [concreteStructTy] UnitTy) ->
               let mappings = unifySignatures originalStructTy concreteStructTy
                   correctedMembers = replaceGenericTypeSymbolsOnMembers mappings membersXObjs
                   memberPairs = memberXObjsToPairs correctedMembers
               in  if typeIsGeneric concreteStructTy
                   then []
                   else concatMap (depsOfPolymorphicFunction typeEnv env [] "delete" . typesDeleterFunctionType)
                                  (filter (isManaged typeEnv) (map snd memberPairs)))

-- | Generate the C code for deleting a single member of the deftype.
-- | TODO: Should return an Either since this can fail!
memberDeletion :: TypeEnv -> Env -> (String, Ty) -> String
memberDeletion typeEnv env (memberName, memberType) =
  case findFunctionForMember typeEnv env "delete" (typesDeleterFunctionType memberType) (memberName, memberType) of
    FunctionFound functionFullName -> "    " ++ functionFullName ++ "(p." ++ memberName ++ ");"
    FunctionNotFound msg -> error msg
    FunctionIgnored -> "    /* Ignore non-managed member '" ++ memberName ++ "' */"

-- | The template for the 'copy' function of a deftype.
templateCopy :: TypeEnv -> Env -> [(String, Ty)] -> Template
templateCopy typeEnv env members =
  Template
   (FuncTy [RefTy (VarTy "p")] (VarTy "p"))
   (const (toTemplate "$p $NAME($p* pRef)"))
   (const (toTemplate $ unlines [ "$DECL {"
                                , "    $p copy = *pRef;"
                                , joinWith "\n" (map (memberCopy typeEnv env) members)
                                , "    return copy;"
                                , "}"]))
   (\_ -> concatMap (depsOfPolymorphicFunction typeEnv env [] "copy" . typesCopyFunctionType)
                    (filter (isManaged typeEnv) (map snd members)))

templateGenericCopy :: [String] -> Ty -> [XObj] -> (String, Binder)
templateGenericCopy pathStrings originalStructTy membersXObjs =
  defineTypeParameterizedTemplate templateCreator path (FuncTy [RefTy originalStructTy] originalStructTy)
  where path = SymPath pathStrings "copy"
        t = (FuncTy [RefTy (VarTy "p")] (VarTy "p"))
        templateCreator = TemplateCreator $
          \typeEnv env ->
            Template
            t
            (const (toTemplate "$p $NAME($p* pRef)"))
            (\(FuncTy [RefTy concreteStructTy] _) ->
               let mappings = unifySignatures originalStructTy concreteStructTy
                   correctedMembers = replaceGenericTypeSymbolsOnMembers mappings membersXObjs
                   memberPairs = memberXObjsToPairs correctedMembers
               in  (toTemplate $ unlines [ "$DECL {"
                                         , "    $p copy = *pRef;"
                                         , joinWith "\n" (map (memberCopy typeEnv env) memberPairs)
                                         , "    return copy;"
                                         , "}"]))
            (\(FuncTy [RefTy concreteStructTy] _) ->
               let mappings = unifySignatures originalStructTy concreteStructTy
                   correctedMembers = replaceGenericTypeSymbolsOnMembers mappings membersXObjs
                   memberPairs = memberXObjsToPairs correctedMembers
               in  if typeIsGeneric concreteStructTy
                   then []
                   else concatMap (depsOfPolymorphicFunction typeEnv env [] "copy" . typesCopyFunctionType)
                                  (filter (isManaged typeEnv) (map snd memberPairs)))

-- | Generate the C code for copying the member of a deftype.
-- | TODO: Should return an Either since this can fail!
memberCopy :: TypeEnv -> Env -> (String, Ty) -> String
memberCopy typeEnv env (memberName, memberType) =
  case findFunctionForMember typeEnv env "copy" (typesCopyFunctionType memberType) (memberName, memberType) of
    FunctionFound functionFullName ->
      "    copy." ++ memberName ++ " = " ++ functionFullName ++ "(&(pRef->" ++ memberName ++ "));"
    FunctionNotFound msg -> error msg
    FunctionIgnored -> "    /* Ignore non-managed member '" ++ memberName ++ "' */"


-- | Will generate getters/setters/updaters when registering external types
-- | i.e. (register-type VRUnicornData [hp Int, magic Float])
bindingsForRegisteredType :: TypeEnv -> Env -> [String] -> String -> [XObj] -> Maybe Info -> Either String (String, XObj, [XObj])
bindingsForRegisteredType typeEnv env pathStrings typeName rest i =
  let typeModuleName = typeName
      emptyTypeModuleEnv = Env (Map.fromList []) (Just env) (Just typeModuleName) [] ExternalEnv
      insidePath = pathStrings ++ [typeModuleName]
  in case validateMembers typeEnv [] rest of
       Left err -> Left err
       Right _ ->
         case
           do let structTy = StructTy typeName []
              okInit <- templateForInit insidePath structTy rest
              --okNew <- templateForNew insidePath structTy rest
              (okStr, strDeps) <- templateForStr typeEnv env insidePath structTy rest
              (binders, deps) <- templatesForMembers typeEnv env insidePath structTy rest
              let moduleEnvWithBindings = addListOfBindings emptyTypeModuleEnv (okInit : okStr : binders)
                  typeModuleXObj = XObj (Mod moduleEnvWithBindings) i (Just ModuleTy)
              return (typeModuleName, typeModuleXObj, deps ++ strDeps)
         of
           Just ok ->
             Right ok
           Nothing ->
             Left "Something's wrong with the templates..." -- TODO: Better messages here!

-- | If the type is just a type variable; create a template type variable by appending $ in front of it's name
templitizeTy :: Ty -> String
templitizeTy t =
  (if isFullyGenericType t then "$" else "") ++ tyToC t
