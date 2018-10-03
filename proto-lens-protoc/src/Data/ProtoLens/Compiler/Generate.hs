-- Copyright 2016 Google Inc. All Rights Reserved.
--
-- Use of this source code is governed by a BSD-style
-- license that can be found in the LICENSE file or at
-- https://developers.google.com/open-source/licenses/bsd

-- | This module builds the actual, generated Haskell file
-- for a given input .proto file.
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
module Data.ProtoLens.Compiler.Generate(
    generateModule,
    fileSyntaxType,
    ModifyImports,
    reexported,
    ) where


import Control.Arrow (second)
import qualified Data.Foldable as F
import qualified Data.List as List
import qualified Data.Map as Map
import Data.Maybe (isNothing, isJust)
import Data.Monoid ((<>))
import Data.Ord (comparing)
import qualified Data.Set as Set
import Data.String (fromString)
import Data.Text (unpack)
import qualified Data.Text as T
import Data.Tuple (swap)
import Lens.Family2 ((^.))
import Text.Printf (printf)

import Proto.Google.Protobuf.Descriptor
    ( EnumValueDescriptorProto
    , FieldDescriptorProto
    , FieldDescriptorProto'Label(..)
    , FieldDescriptorProto'Type(..)
    , FileDescriptorProto
    )
import Proto.Google.Protobuf.Descriptor_Fields
    ( defaultValue
    , label
    , mapEntry
    , maybe'oneofIndex
    , maybe'packed
    , name
    , number
    , options
    , syntax
    , type'
    , typeName
    )

import Data.ProtoLens.Compiler.Combinators
import Data.ProtoLens.Compiler.Definitions

data SyntaxType = Proto2 | Proto3
    deriving (Show, Eq)

fileSyntaxType :: FileDescriptorProto -> SyntaxType
fileSyntaxType f = case f ^. syntax of
    "proto2" -> Proto2
    "proto3" -> Proto3
    "" -> Proto2  -- The proto compiler doesn't set syntax for proto2 files.
    s -> error $ "Unknown syntax type " ++ show s

-- Whether to import the "Runtime" modules or the originals;
-- e.g., Data.ProtoLens.Runtime.Data.Map vs Data.Map.
data UseRuntime = UseRuntime | UseOriginal
    deriving (Eq, Read)

-- | Generate a Haskell module for the given input file(s).
-- input contains all defined names, incl. those in this module
generateModule :: ModuleName
               -> [ModuleName]  -- ^ The imported modules
               -> SyntaxType
               -> ModifyImports
               -> Env Name      -- ^ Definitions in this file
               -> Env QName     -- ^ Definitions in the imported modules
               -> [ServiceInfo]
               -> [Module]
generateModule modName imports syntaxType modifyImport definitions importedEnv services
    = [ Module modName
                (Just $ (serviceExports ++) $ concatMap generateExports $ Map.elems definitions)
                pragmas
                (mainImports ++ sharedImports)
          $ (concatMap generateDecls $ Map.toList definitions)
         ++ map uncommented (concatMap (generateServiceDecls env) services)
      , Module fieldModName
                Nothing
                pragmas
                sharedImports
          . map uncommented
          $ concatMap generateFieldDecls allLensNames
      ]
  where
    fieldModName = modifyModuleName (++ "_Fields") modName
    pragmas =
          [ languagePragma $ map fromString
              ["ScopedTypeVariables", "DataKinds", "TypeFamilies",
               "UndecidableInstances", "GeneralizedNewtypeDeriving",
               "MultiParamTypeClasses", "FlexibleContexts", "FlexibleInstances",
               "PatternSynonyms", "MagicHash", "NoImplicitPrelude",
               "DataKinds"]
              -- Allow unused imports in case we don't import anything from
              -- Data.Text, Data.Int, etc.
          , optionsGhcPragma "-fno-warn-unused-imports"
          -- haskell-src-exts doesn't support exporting `Foo(..., A, B)`
          -- in a single entry, so we use two: `Foo(..)` and `Foo(A, B)`.
          , optionsGhcPragma "-fno-warn-duplicate-exports"
          ]
    mainImports = map (modifyImport . importSimple)
                    [ "Control.DeepSeq", "Lens.Labels.Prism" ]
    sharedImports = map (modifyImport . importSimple)
              [ "Prelude", "Data.Int", "Data.Word"
              , "Data.ProtoLens", "Data.ProtoLens.Message.Enum", "Data.ProtoLens.Service.Types"
              , "Lens.Family2", "Lens.Family2.Unchecked"
              , "Data.Text",  "Data.Map", "Data.ByteString", "Data.ByteString.Char8"
              , "Lens.Labels", "Text.Read", "Data.Vector.Unboxed"
              ]
            ++ map importSimple imports
    env = Map.union (unqualifyEnv definitions) importedEnv
    generateDecls (protoName, Message m)
        = generateMessageDecls fieldModName syntaxType env (stripDotPrefix protoName) m
       ++ map uncommented (concatMap (generatePrisms env) (messageOneofFields m))
    generateDecls (_, Enum e) = map uncommented $ generateEnumDecls syntaxType e
    generateExports (Message m) = generateMessageExports m
                               ++ concatMap generatePrismExports (messageOneofFields m)
    generateExports (Enum e) = generateEnumExports syntaxType e
    serviceExports = fmap generateServiceExports services
    allLensNames = F.toList $ Set.fromList
        [ lensSymbol inst
        | Message m <- Map.elems definitions
        , info <- allMessageFields syntaxType env m
        , inst <- recordFieldLenses info
        ]
    -- The Env uses the convention that Message names are prefixed with '.'
    -- (since that's how the FileDescriptorProto refers to them).
    -- Strip that off when defining MessageDescriptor.messageName.
    stripDotPrefix s
        | Just ('.', s') <- T.uncons s = s'
        | otherwise = s

allMessageFields :: SyntaxType -> Env QName -> MessageInfo Name -> [RecordField]
allMessageFields syntaxType env info =
    map (plainRecordField syntaxType env) (messageFields info)
        ++ map (oneofRecordField env) (messageOneofFields info)

importSimple :: ModuleName -> ImportDecl ()
importSimple m = ImportDecl
    { importAnn = ()
    , importModule = m
    -- Import qualified to avoid clashes with names defined in this module.
    , importQualified = True
    , importSrc = False
    , importSafe = False
    , importPkg = Nothing
    , importAs = Nothing
    , importSpecs = Nothing
    }

type ModifyImports = ImportDecl () -> ImportDecl ()

reexported :: ModifyImports
reexported imp@ImportDecl {importModule = m}
    = imp { importAs = Just m, importModule = m' }
  where
    m' = fromString $ "Data.ProtoLens.Runtime." ++ prettyPrint m

messageComment :: ModuleName -> Name -> [RecordField] -> String
messageComment fieldModName n fields = unlines
    $ ["Fields :", ""]
        ++ map item (concatMap recordFieldLenses fields)
  where
    item :: LensInstance -> String
    item l = (printf "    * '%s.%s' @:: %s@"
                 (prettyPrint fieldModName)
                 (prettyPrint $ nameFromSymbol $ lensSymbol l)
                 (prettyPrint $ "Lens'" @@ t @@ (lensFieldType l)))
    t = tyCon (unQual n)

generateMessageExports :: MessageInfo Name -> [ExportSpec]
generateMessageExports m =
    -- Hide the message contructor, but expose "oneof" case constructors.
    exportWith (unQual $ messageName m) []
        : map (exportAll . unQual . oneofTypeName)
                (messageOneofFields m)

generateServiceDecls :: Env QName -> ServiceInfo -> [Decl]
generateServiceDecls env si =
    -- data MyService = MyService
    [ dataDecl serverDataName
      [ recDecl serverDataName []
      ]
      $ deriving' []
    ] ++
    -- instance Data.ProtoLens.Service.Types.Service MyService where
    --     type ServiceName    MyService = "myService"
    --     type ServicePackage MyService = "some.package"
    --     type ServiceMethods MyService = '["normalMethod", "streamingMethod"]
    [ instDeclWithTypes [] ("Data.ProtoLens.Service.Types.Service" `ihApp` [serverRecordType])
        [ instType ("ServiceName" @@ serverRecordType)
                 . tyPromotedString . T.unpack $ serviceName si
        , instType ("ServicePackage" @@ serverRecordType)
                 . tyPromotedString . T.unpack $ servicePackage si
        , instType ("ServiceMethods" @@ serverRecordType)
                 $ tyPromotedList
                      [ tyPromotedString . T.unpack $ methodIdent m
                      | m <- List.sortBy (comparing methodIdent) $ serviceMethods si
                      ]
        ]
    ] ++
    -- instance Data.ProtoLens.Service.Types.HasMethodImpl MyService "normalMethod" where
    --     type MethodInput       MyService "normalMethod" = Foo
    --     type MethodOutput      MyService "normalMethod" = Bar
    --     type IsClientStreaming MyService "normalMethod" = 'False
    --     type IsServerStreaming MyService "normalMethod" = 'False
    [ instDeclWithTypes [] ("Data.ProtoLens.Service.Types.HasMethodImpl" `ihApp` [serverRecordType, instanceHead])
        [ instType ("MethodName" @@ serverRecordType @@ instanceHead)
                 . tyPromotedString . T.unpack $ methodName m
        , instType ("MethodInput" @@ serverRecordType @@ instanceHead)
                 . lookupType $ methodInput m
        , instType ("MethodOutput" @@ serverRecordType @@ instanceHead)
                 . lookupType $ methodOutput m
        , instType ("MethodStreamingType" @@ serverRecordType @@ instanceHead)
                 . tyPromotedCon
                 $ case (methodClientStreaming m, methodServerStreaming m) of
                     (False, False) -> "Data.ProtoLens.Service.Types.NonStreaming"
                     (True,  False) -> "Data.ProtoLens.Service.Types.ClientStreaming"
                     (False, True)  -> "Data.ProtoLens.Service.Types.ServerStreaming"
                     (True,  True)  -> "Data.ProtoLens.Service.Types.BiDiStreaming"
        ]
    | m <- serviceMethods si
    , let instanceHead = tyPromotedString (T.unpack $ methodIdent m)
    ]
  where
    serverDataName = fromString . T.unpack $ serviceName si
    serverRecordType = tyCon $ unQual serverDataName

    lookupType t = case definedType t env of
                       Message msg -> tyCon $ messageName msg
                       Enum _ -> error "Service must have a message type"


generateMessageDecls :: ModuleName -> SyntaxType -> Env QName -> T.Text -> MessageInfo Name -> [CommentedDecl]
generateMessageDecls fieldModName syntaxType env protoName info =
    -- data Bar = Bar {
    --    foo :: Baz
    -- }
    [ commented (messageComment fieldModName (messageName info) allFields)
        $ dataDecl dataName
            [recDecl dataName $
                      [ (recordFieldName f, recordFieldType f)
                      | f <- allFields
                      ]
                      ++ [(messageUnknownFields info, "Data.ProtoLens.FieldSet")]
            ]
            $ deriving' ["Prelude.Eq", "Prelude.Ord"]
    -- instance Show Bar where
    --   showsPrec __x __s = showChar '{' (showString (showMessageShort __x) (showChar '}' s))
    , uncommented $
        instDecl [] ("Prelude.Show" `ihApp` [dataType])
            [[match "showsPrec" ["_", "__x", "__s"]
                $ "Prelude.showChar" @@ charExp '{'
                    @@ ("Prelude.showString" @@ ("Data.ProtoLens.showMessageShort" @@ "__x")
                        @@ ("Prelude.showChar" @@ charExp '}' @@ "__s"))]]
    ] ++
    -- oneof field data type declarations
    -- proto: message Foo {
    --          oneof bar {
    --            float c = 1;
    --            Sub s = 2;
    --          }
    --        }
    -- haskell: data Foo'Bar = Foo'Bar'c !Prelude.Float
    --                       | Foo'Bar's !Sub
    [ uncommented $ dataDecl (oneofTypeName oneofInfo)
      [ conDecl consName [hsFieldType env $ fieldDescriptor f]
      | c <- oneofCases oneofInfo
      , let f = caseField c
      , let consName = caseConstructorName c
      ]
      $ deriving' ["Prelude.Show", "Prelude.Eq", "Prelude.Ord"]
    | oneofInfo <- messageOneofFields info
    ] ++
    -- instance HasLens' Foo "foo" Bar
    --   lensOf _ = ...
    -- Note: for optional fields, this generates an instance both for "foo" and
    -- for "maybe'foo" (see plainRecordField below).
    [ uncommented $ instDecl []
        ("Lens.Labels.HasLens'" `ihApp`
            [dataType, sym, tyParen t])
            [[match "lensOf'" [pWildCard] $
                "Prelude.."
                    @@ rawFieldAccessor (unQual $ recordFieldName li)
                    @@ lensExp i]]
    | li <- allFields
    , i <- recordFieldLenses li
    , let t = lensFieldType i
    , let sym = promoteSymbol $ lensSymbol i
    ]
    ++
    -- instance Message.Message Bar where
    [ uncommented $ instDecl [] ("Data.ProtoLens.Message" `ihApp` [dataType])
        $ messageInstance syntaxType env protoName info
    -- instance NFData Bar where
    , uncommented $ instDecl [] ("Control.DeepSeq.NFData" `ihApp` [dataType])
        [[match "rnf" [] $ messageRnfExpr info]]
    ] ++
    -- instance NFData Foo'Bar where
    [ uncommented $
        instDecl [] ("Control.DeepSeq.NFData" `ihApp`
                        [tyCon $ unQual $ oneofTypeName o])
        [map oneofRnfMatch $ oneofCases o]
    | o <- messageOneofFields info
    ]
  where
    dataType = tyCon $ unQual dataName
    dataName = messageName info
    allFields = allMessageFields syntaxType env info

-- oneof Prism declarations
-- proto: message Foo {
--          oneof bar {
--            float c = 1;
--            Sub s = 2;
--          }
--        }
-- haskell: _Foo'C :: Prism' Bar'C Float
--          _Foo'S :: Prism' Bar'S Sub
--
--  example of the function definition for _Foo'C:
-- _Foo'C :: Lens.Prism.Prism' Bar'C Float
-- _Foo'C
--   = Lens.Prism.prism' Bar'C
--       (\ p__ ->
--          case p__ of
--              Bar'C p__val -> Prelude.Just p__val
--              _otherwise -> Prelude.Nothing)
generatePrisms :: Env QName -> OneofInfo -> [Decl]
generatePrisms env oneofInfo =
    if length cases > 1
       then concatMap (generatePrism altOtherwise) cases
       else concatMap (generatePrism mempty) cases
    where
        cases = oneofCases oneofInfo
        altOtherwise = [ alt "_otherwise" "Prelude.Nothing" ]

        -- Generate type signature
        -- e.g. Prism' Bar'C Float
        generateTypeSig f funName =
            typeSig [funName] $ "Lens.Labels.Prism.Prism'"
                                -- The oneof sum type name
                             @@ (tyCon . unQual $ oneofTypeName oneofInfo)
                                -- The field contained in the sum
                             @@ (hsFieldType env $ fieldDescriptor f)
        -- Generate function definition
        -- Prism' is constructed with Constructor for building value
        -- and Deconstructor and wrapping in Just for getting value
        generateFunDef otherwiseCase consName =
               "Lens.Labels.Prism.prism'"
               -- Sum type constructor
            @@ con (unQual consName)
               -- Case deconstruction
            @@ (lambda ["p__"] $
                    case' "p__" $
                        [ alt (pApp (unQual consName) ["p__val"])
                              ("Prelude.Just" @@ "p__val")
                        ]
                       -- We want to generate the otherwise case
                       -- depending on the amount of sum type cases there are
                       ++ otherwiseCase
               )
        generatePrism :: [Alt] -> OneofCase -> [Decl]
        generatePrism otherwiseCase oneofCase =
            let consName = caseConstructorName oneofCase
                prismName = casePrismName oneofCase
            in [ generateTypeSig (caseField oneofCase) prismName
               , funBind [ match prismName [] $ generateFunDef otherwiseCase consName ]
               ]

generatePrismExports :: OneofInfo -> [ExportSpec]
generatePrismExports = map (exportVar . unQual . casePrismName) . oneofCases

generateEnumExports :: SyntaxType -> EnumInfo Name -> [ExportSpec]
generateEnumExports syntaxType e = [exportAll n, exportWith n aliases] ++ proto3NewType
  where
    n = unQual $ enumName e
    aliases = [enumValueName v | v <- enumValues e, needsManualExport v]
    needsManualExport v = isJust (enumAliasOf v)
    proto3NewType = if syntaxType == Proto3
      then [exportVar . unQual $ enumUnrecognizedValueName e]
      else []

generateServiceExports :: ServiceInfo -> ExportSpec
generateServiceExports si = exportAll $ unQual $ fromString $ T.unpack $ serviceName si

generateEnumDecls :: SyntaxType -> EnumInfo Name -> [Decl]
generateEnumDecls syntaxType info =
    -- Proto3-only:
    -- newtype FooEnum'UnrecognizedValue = FooEnum'UnrecognizedValue Data.Int.Int32
    --   deriving (Prelude.Eq, Prelude.Ord, Prelude.Show, Prelude.Read)
    [ newtypeDecl unrecognizedValueName
       "Data.Int.Int32"
        $ deriving' ["Prelude.Eq", "Prelude.Ord", "Prelude.Show"]
    | syntaxType == Proto3
    ]
    ++

    -- data FooEnum
    --     = Enum1
    --     | Enum2
    --     | FooEnum'Unrecognized !FooEnum'UnrecognizedValue
    --   deriving (Prelude.Show, Prelude.Eq, Prelude.Ord, Prelude.Read)
    [ dataDecl dataName
        (  (flip conDecl [] <$> constructorNames)
        ++ [ conDecl unrecognizedName [tyCon $ unQual unrecognizedValueName]
           | syntaxType == Proto3
           ]
        )
        $ deriving' ["Prelude.Show", "Prelude.Eq", "Prelude.Ord"]

    -- instance Data.ProtoLens.MessageEnum FooEnum where
    --       maybeToEnum 0 = Prelude.Just Enum1
    --       maybeToEnum 3 = Prelude.Just Enum2
    --       maybeToEnum k
    --         -- Proto3:
    --         = Prelude.Just
    --             (FooEnum'Unrecognized
    --               (FooEnum'UnrecognizedValue (Prelude.fromIntegral k)))
    --         -- Proto2:
    --         = Nothing
    --
    --       showEnum Foo'Enum2 = "Enum2"
    --       showEnum Foo'Enum1 = "Enum1"
    --       showEnum (FooEnum'Unrecognized (FooEnum'UnrecognizedValue k))
    --         = Prelude.show k
    --
    --       readEnum k
    --           | k == "Enum2a" = Prelude.Just Enum2a -- alias
    --           | k == "Enum2" = Prelude.Just Enum2
    --           | k == "Enum1" = Prelude.Just Enum1
    --       readEnum k = Text.Read.readMaybe k >>= maybeToEnum
    , instDecl [] ("Data.ProtoLens.MessageEnum" `ihApp` [dataType])
        [ [ match "maybeToEnum" [pLitInt k] $ "Prelude.Just" @@ con (unQual c)
          | (c, k) <- constructorNumbers
          ]
          ++
          [ case syntaxType of
              Proto2 -> match "maybeToEnum" [pWildCard] "Prelude.Nothing"
              Proto3 -> match "maybeToEnum" ["k"]
                          $ "Prelude.Just" @@
                            (con (unQual unrecognizedName)
                              @@ (con (unQual unrecognizedValueName)
                                  @@ ("Prelude.fromIntegral" @@ "k")
                                 )
                            )
          ]
        , [ match "showEnum" [pApp (unQual n) []]
              $ stringExp pn
          | v <- filter (null . enumAliasOf) $ enumValues info
          , let n = enumValueName v
          , let pn = T.unpack $ enumValueDescriptor v ^. name
          ] ++
          [ match "showEnum" [pApp (unQual unrecognizedName)
                              [pApp (unQual unrecognizedValueName) [pVar "k"]]
                            ]
                  $ "Prelude.show" @@ "k"
          | syntaxType == Proto3
          ]
        , [ guardedMatch "readEnum" [pVar "k"]
              [ ("Prelude.==" @@ "k" @@ stringExp pn, "Prelude.Just" @@ con (unQual n))
              | v <- enumValues info
              , let n = enumValueName v
              , let pn = T.unpack $ enumValueDescriptor v ^. name
              ]
          , match "readEnum" [pVar "k"] $ "Prelude.>>="
                                      @@ ("Text.Read.readMaybe" @@ "k")
                                      @@ "Data.ProtoLens.maybeToEnum"]
        ]

      -- instance Bounded Foo where
      --    minBound = Foo1
      --    maxBound = FooN
      , instDecl [] ("Prelude.Bounded" `ihApp` [dataType])
          [[ match "minBound" [] $ con $ unQual minBoundName
          , match "maxBound" [] $ con $ unQual maxBoundName
          ]]

      -- instance Enum Foo where
      --    toEnum k = maybe (error ("Foo.toEnum: unknown argument for enum Foo: "
      --                                ++ show k))
      --                  id (maybeToEnum k)
      --    fromEnum Foo1 = 1
      --    fromEnum Foo2 = 2
      --    ..
      --    succ FooN = error "Foo.succ: bad argument FooN."
      --    succ Foo1 = Foo2
      --    succ Foo2 = Foo3
      --    ..
      --    pred Foo1 = error "Foo.succ: bad argument Foo1."
      --    pred Foo2 = Foo1
      --    pred Foo3 = Foo2
      --    ..
      --    enumFrom = messageEnumFrom
      --    enumFromTo = messageEnumFromTo
      --    enumFromThen = messageEnumFromThen
      --    enumFromThenTo = messageEnumFromThenTo
      , instDecl [] ("Prelude.Enum" `ihApp` [dataType])
        [[match "toEnum" ["k__"]
                  $ "Prelude.maybe" @@ errorMessageExpr @@ "Prelude.id"
                        @@ ("Data.ProtoLens.maybeToEnum" @@ "k__")]
        , [ match "fromEnum" [pApp (unQual c) []] $ litInt k
          | (c, k) <- constructorNumbers
          ]
          ++
          [ match "fromEnum" [pApp (unQual unrecognizedName)
                              [pApp (unQual unrecognizedValueName) [pVar "k"]]
                            ]
                  $ "Prelude.fromIntegral" @@ "k"
          | syntaxType == Proto3
          ]
        , succDecl "succ" maxBoundName succPairs
        , succDecl "pred" minBoundName $ map swap succPairs
        , alias "enumFrom" "Data.ProtoLens.Message.Enum.messageEnumFrom"
        , alias "enumFromTo" "Data.ProtoLens.Message.Enum.messageEnumFromTo"
        , alias "enumFromThen" "Data.ProtoLens.Message.Enum.messageEnumFromThen"
        , alias "enumFromThenTo"
            "Data.ProtoLens.Message.Enum.messageEnumFromThenTo"
        ]

    -- instance Data.ProtoLens.FieldDefault Foo where
    --   fieldDefault = FirstEnumValue
    , instDecl [] ("Data.ProtoLens.FieldDefault" `ihApp` [dataType])
        [[match "fieldDefault" [] defaultCon]]

    -- instance NFData Foo where
    --   rnf x__ = seq x__ ()
    -- (Trivial since enum types are already strict)
    , instDecl [] ("Control.DeepSeq.NFData" `ihApp` [dataType])
        [[ match "rnf" ["x__"] $ "Prelude.seq" @@ "x__" @@ "()" ]]
    ] ++

    -- pattern Enum2a :: FooEnum
    -- pattern Enum2a = Enum2
    concat
        [ [ patSynSig aliasName dataType
          , patSyn (pVar aliasName) (pVar originalName)
          ]
        | EnumValueInfo
            { enumValueName = aliasName
            , enumAliasOf = Just originalName
            } <- enumValues info
        ]

  where
    EnumInfo { enumName = dataName
             , enumUnrecognizedName = unrecognizedName
             , enumUnrecognizedValueName = unrecognizedValueName
             , enumDescriptor = ed
             } = info
    errorMessage = "toEnum: unknown value for enum " ++ unpack (ed ^. name)
                      ++ ": "

    errorMessageExpr = "Prelude.error"
                          @@ ("Prelude.++" @@ stringExp errorMessage
                              @@ ("Prelude.show" @@ "k__"))
    alias funName implName = [match funName [] implName]

    dataType = tyCon $ unQual dataName

    constructors :: [(Name, EnumValueDescriptorProto)]
    constructors = List.sortBy (comparing ((^. number) . snd))
                            [(n, d) | EnumValueInfo
                                { enumValueName = n
                                , enumValueDescriptor = d
                                , enumAliasOf = Nothing
                                } <- enumValues info
                            ]
    constructorNames = map fst constructors

    defaultCon = con $ unQual $ head constructorNames

    minBoundName = head constructorNames
    maxBoundName = last constructorNames

    constructorNumbers = map (second (fromIntegral . (^. number))) constructors

    succPairs = zip constructorNames $ tail constructorNames
    succDecl funName boundName thePairs =
        match funName [pApp (unQual boundName) []]
            ("Prelude.error" @@ stringExp (concat
                [ prettyPrint dataName, ".", prettyPrint funName, ": bad argument "
                , prettyPrint boundName, ". This value would be out of bounds."
                ]))
        :
        [ match funName [pApp (unQual from) []] $ con $ unQual to
        | (from, to) <- thePairs
        ]
        ++
        [ match funName [pApp (unQual unrecognizedName) [pWildCard]]
            ("Prelude.error" @@ stringExp (concat
                [ prettyPrint dataName, ".", prettyPrint funName, ": bad argument: unrecognized value"
                ]))
        | syntaxType == Proto3
        ]

generateFieldDecls :: Symbol -> [Decl]
generateFieldDecls xStr =
    -- foo :: forall f s a
    --        . (Functor f, HasLens s x a) => LensLike' f s a
    -- foo = lensOf (Proxy# :: Proxy# x)
    [ typeSig [x]
          $ tyForAll ["f", "s", "a"]
                  [classA "Prelude.Functor" ["f"],
                   classA "Lens.Labels.HasLens'" ["s", xSym, "a"]]
                    $ "Lens.Family2.LensLike'" @@ "f" @@ "s" @@ "a"
    , funBind [match x [] $ lensOfExp xStr]
    ]
  where
    x = nameFromSymbol xStr
    xSym = promoteSymbol xStr

------------------------------------------

-- | An individual field of the Haskell type corresponding to a proto message.
data RecordField = RecordField
    { recordFieldName :: Name  -- ^ The Haskell name of this field (unique
                               --   within the module).
    , recordFieldType :: Type  -- ^ Internal type in the record
    , recordFieldLenses :: [LensInstance]
        -- ^ All of the (overloaded) lenses accessing this record field.
    }

-- | An instance of HasLens' for a particular field.
data LensInstance = LensInstance
    { lensSymbol :: Symbol
          -- ^ The overloaded name for this lens.
    , lensFieldType :: Type
          -- ^ The type pointed to from this lens.
    , lensExp :: Exp
        -- ^ A lens from the recordFieldType to the lensFieldType; i.e.,
        -- from how it's actually stored in the Haskell record to how the
        -- lens views it.
    }

-- | Compile information about the record field type and type/class instances
-- for this particular field.
--
-- Used for "plain" record fields that are not part of a oneof.
plainRecordField :: SyntaxType -> Env QName -> FieldInfo -> RecordField
plainRecordField syntaxType env f = case fd ^. label of
    -- data Foo = Foo { _Foo_bar :: Bar }
    -- type instance Field "bar" Foo = Bar
    FieldDescriptorProto'LABEL_REQUIRED
        -> recordField baseType
                  [LensInstance
                      { lensSymbol = baseName
                      , lensFieldType = baseType
                      , lensExp = rawAccessor
                      }]
    FieldDescriptorProto'LABEL_OPTIONAL
        | isDefaultingOptional syntaxType fd
              -> recordField baseType
                    [LensInstance
                      { lensSymbol = baseName
                      , lensFieldType = baseType
                      , lensExp = rawAccessor
                      }]
    -- data Foo = Foo { _Foo_bar :: Maybe Bar }
    -- type instance Field "bar" Foo = Bar
    -- type instance Field "maybe'bar" Foo = Maybe Bar
        | otherwise ->
              recordField maybeType
                  [LensInstance
                      { lensSymbol = baseName
                      , lensFieldType = baseType
                      , lensExp = maybeAccessor
                      }
                  , LensInstance
                      { lensSymbol = "maybe'" <> baseName
                      , lensFieldType = maybeType
                      , lensExp = rawAccessor
                      }
                  ]
    FieldDescriptorProto'LABEL_REPEATED
        -- data Foo = Foo { _Foo_bar :: Map Bar Baz }
        -- type instance Field "foo" Foo = Map Bar Baz
        | Just (k,v) <- getMapFields env fd -> let
            mapType = "Data.Map.Map" @@ hsFieldType env (fieldDescriptor k)
                                     @@ hsFieldType env (fieldDescriptor v)
            in recordField mapType
                  [LensInstance
                       { lensSymbol = baseName
                       , lensFieldType = mapType
                       , lensExp = rawAccessor
                       }]
        -- data Foo = Foo { _Foo_bar :: [Bar] }
        -- type instance Field "bar" Foo = [Bar]
        | isPackedField syntaxType fd
            -> recordField packedType
                  [LensInstance
                      { lensSymbol = baseName
                      , lensFieldType = packedType
                      , lensExp = rawAccessor
                      }]
        | otherwise -> recordField listType
                  [LensInstance
                      { lensSymbol = baseName
                      , lensFieldType = listType
                      , lensExp = rawAccessor
                      }]
  where
    recordField = RecordField (haskellRecordFieldName $ plainFieldName f)
    baseName = overloadedName $ plainFieldName f
    fd = fieldDescriptor f
    baseType = hsFieldType env fd
    maybeType = "Prelude.Maybe" @@ baseType
    listType = tyList baseType
    packedType = "Data.Vector.Unboxed.Vector" @@ baseType
    rawAccessor = "Prelude.id"
    maybeAccessor = "Data.ProtoLens.maybeLens"
                          @@ hsFieldValueDefault env fd


oneofRecordField :: Env QName -> OneofInfo -> RecordField
oneofRecordField env oneofInfo
    = RecordField
        { recordFieldName = haskellRecordFieldName $ oneofFieldName oneofInfo
        , recordFieldType =
              "Prelude.Maybe" @@ tyCon (unQual $ oneofTypeName oneofInfo)
        , recordFieldLenses = lenses
        }
  where
    lenses =
        -- Only generate a "maybe" version of this lens,
        -- since oneofs don't have a notion of a "default" case.
        -- data Foo = Foo { _Foo'bar = Maybe Foo'Bar }
        -- type instance Field "maybe'bar" Foo = Maybe Foo'Bar
        [LensInstance
          { lensSymbol = "maybe'" <> overloadedName
                                        (oneofFieldName oneofInfo)
          , lensFieldType =
                "Prelude.Maybe" @@ tyCon (unQual $ oneofTypeName oneofInfo)
          , lensExp = "Prelude.id"
          }
         ]
         ++ concat
          -- Generate the same lenses for each sub-field of the oneof
          -- as if they were proto2 optional fields.
          -- type instance Field "bar" Foo = Bar
          -- type instance Field "maybe'bar" Foo = Maybe Bar
            [ [ LensInstance
                { lensSymbol = maybeName
                , lensFieldType = "Prelude.Maybe" @@ baseType
                , lensExp = oneofFieldAccessor c
                }
              , LensInstance
                { lensSymbol = baseName
                , lensFieldType = baseType
                , lensExp = "Prelude.."
                                @@ oneofFieldAccessor c
                                @@ ("Data.ProtoLens.maybeLens"
                                              @@ hsFieldValueDefault env
                                                    (fieldDescriptor f))
                }
              ]
            | c <- oneofCases oneofInfo
            , let f = caseField c
            , let baseName = overloadedName $ plainFieldName f
            , let baseType = hsFieldType env $ fieldDescriptor f
            , let maybeName = "maybe'" <> baseName
            ]

-- Get the key/value types of this type, if it is really a map.
getMapFields :: Env QName -> FieldDescriptorProto
             -> Maybe (FieldInfo, FieldInfo)
getMapFields env f
    | f ^. type' == FieldDescriptorProto'TYPE_MESSAGE
    , Message m@MessageInfo { messageDescriptor = d } <- definedFieldType f env
    , d ^. options.mapEntry
    , [f1, f2] <- messageFields m = Just (f1, f2)
    | otherwise = Nothing

hsFieldType :: Env QName -> FieldDescriptorProto -> Type
hsFieldType env fd = case fd ^. type' of
    FieldDescriptorProto'TYPE_DOUBLE -> "Prelude.Double"
    FieldDescriptorProto'TYPE_FLOAT -> "Prelude.Float"
    FieldDescriptorProto'TYPE_INT64 -> "Data.Int.Int64"
    FieldDescriptorProto'TYPE_UINT64 -> "Data.Word.Word64"
    FieldDescriptorProto'TYPE_INT32 -> "Data.Int.Int32"
    FieldDescriptorProto'TYPE_FIXED64 -> "Data.Word.Word64"
    FieldDescriptorProto'TYPE_FIXED32 -> "Data.Word.Word32"
    FieldDescriptorProto'TYPE_BOOL -> "Prelude.Bool"
    FieldDescriptorProto'TYPE_STRING -> "Data.Text.Text"
    FieldDescriptorProto'TYPE_GROUP
        | Message m <- definedFieldType fd env -> tyCon $ messageName m
        | otherwise -> error $ "expected TYPE_GROUP for type name"
                              ++ unpack (fd ^. typeName)
    FieldDescriptorProto'TYPE_MESSAGE
        | Message m <- definedFieldType fd env -> tyCon $ messageName m
        | otherwise -> error $ "expected TYPE_MESSAGE for type name"
                              ++ unpack (fd ^. typeName)
    FieldDescriptorProto'TYPE_BYTES -> "Data.ByteString.ByteString"
    FieldDescriptorProto'TYPE_UINT32 -> "Data.Word.Word32"
    FieldDescriptorProto'TYPE_ENUM
        | Enum e <- definedFieldType fd env -> tyCon $ enumName e
        | otherwise -> error $ "expected TYPE_ENUM for type name"
                              ++ unpack (fd ^. typeName)
    FieldDescriptorProto'TYPE_SFIXED32 -> "Data.Int.Int32"
    FieldDescriptorProto'TYPE_SFIXED64 -> "Data.Int.Int64"
    FieldDescriptorProto'TYPE_SINT32 -> "Data.Int.Int32"
    FieldDescriptorProto'TYPE_SINT64 -> "Data.Int.Int64"

hsFieldDefault :: SyntaxType -> Env QName -> FieldDescriptorProto -> Exp
hsFieldDefault syntaxType env fd
    = case fd ^. label of
          FieldDescriptorProto'LABEL_OPTIONAL
              | isDefaultingOptional syntaxType fd -> hsFieldValueDefault env fd
              | otherwise -> "Prelude.Nothing"
          FieldDescriptorProto'LABEL_REPEATED
              | Just _ <- getMapFields env fd -> "Data.Map.empty"
              | isPackedField syntaxType fd -> "Data.Vector.Unboxed.empty"
              | otherwise -> list []
          -- TODO: More sensible initialization of required fields.
          FieldDescriptorProto'LABEL_REQUIRED -> hsFieldValueDefault env fd

hsFieldValueDefault :: Env QName -> FieldDescriptorProto -> Exp
hsFieldValueDefault env fd = case fd ^. type' of
    FieldDescriptorProto'TYPE_MESSAGE -> "Data.ProtoLens.defMessage"
    FieldDescriptorProto'TYPE_GROUP -> "Data.ProtoLens.defMessage"
    FieldDescriptorProto'TYPE_ENUM
        | T.null def -> "Data.ProtoLens.fieldDefault"
        | Enum e <- definedFieldType fd env
        , Just v <- List.lookup def [ (enumValueDescriptor v ^. name, enumValueName v)
                                    | v <- enumValues e
                                    ]
            -> con v
        | otherwise -> errorMessage "enum"
    -- The rest of the cases are for scalar fields that have a fieldDefault
    -- instance.
    _ | T.null def -> "Data.ProtoLens.fieldDefault"
    FieldDescriptorProto'TYPE_BOOL
        | def == "true" -> "Prelude.True"
        | def == "false" -> "Prelude.False"
        | otherwise -> errorMessage "bool"
    FieldDescriptorProto'TYPE_STRING
        -> "Data.Text.pack" @@ stringExp (T.unpack def)
    FieldDescriptorProto'TYPE_BYTES
        -> "Data.ByteString.pack"
                @@ list ((mkByte . fromEnum) <$> T.unpack def)
      where mkByte c
              | c > 0 && c < 255 = litInt $ fromIntegral c
              | otherwise = errorMessage "bytes"
    FieldDescriptorProto'TYPE_FLOAT -> defaultFrac $ T.unpack def
    FieldDescriptorProto'TYPE_DOUBLE -> defaultFrac $ T.unpack def
    -- Otherwise, assume it's an integral field:
    _ -> defaultInt $ T.unpack def
  where
    def = fd ^. defaultValue
    errorMessage fieldType
        = error $ "Bad default value " ++ show (T.unpack def)
                    ++ " in default value for " ++ fieldType ++ " field "
                    ++ unpack (fd ^. name)
    -- float/double fields can use nan, inf and -inf as default values.
    -- The Prelude doesn't provide names for them, so we implement
    -- them as division by zero.
    defaultFrac "nan" = "Prelude./" @@ litFrac 0 @@ litFrac 0
    defaultFrac "inf" = "Prelude./" @@ litFrac 1 @@ litFrac 0
    defaultFrac "-inf" = "Prelude./" @@ litFrac (negate 1) @@ litFrac 0
    defaultFrac s = case reads s of
        [(x, "")] -> litFrac $ toRational (x :: Double)
        _ -> errorMessage "fractional"
    defaultInt s = case reads s of
        [(x, "")] -> litInt x
        _ -> errorMessage "integral"

-- | A lens to access an internal field.
--
--   lens _Foo_bar (\x__ y__ -> x__ { _Foo_bar = y__ })
rawFieldAccessor :: QName -> Exp
rawFieldAccessor f = "Lens.Family2.Unchecked.lens" @@ getter @@ setter
  where
    getter = var f
    setter = lambda ["x__", "y__"]
                    $ recUpdate "x__" [fieldUpdate f "y__"]

-- | A lens that maps from a oneof sum type to one of its individual cases.
--
-- For example, with
--     data Foo = Bar Int32 | Baz Int64
--
-- this will generate a lens of type @Lens' (Maybe Foo) (Maybe Int32)@.
--
-- (Recall that oneofs are stored in a proto message as @Maybe Foo@, where
-- 'Nothing' means that it's either set to an unknown value or unset.)
--
-- lens
--   (\ x__ -> case x__ of
--       Prelude.Just (Foo'c x__val) -> Prelude.Just x__val
--       otherwise -> Prelude.Nothing)
--   (\ _ y__ -> fmap Foo'c y__
oneofFieldAccessor :: OneofCase -> Exp
oneofFieldAccessor o
        = "Lens.Family2.Unchecked.lens" @@ getter @@ setter
  where
    consName = caseConstructorName o
    getter = lambda ["x__"] $
        case' "x__"
            [ alt
                (pApp "Prelude.Just" [pApp (unQual consName) ["x__val"]])
                ("Prelude.Just" @@ "x__val")
            , alt
                "_otherwise"
                "Prelude.Nothing"
            ]
    setter = lambda ["_", "y__"]
                $ "Prelude.fmap" @@ con (unQual consName) @@ "y__"

messageInstance :: SyntaxType -> Env QName -> T.Text -> MessageInfo Name -> [[Match]]
messageInstance syntaxType env protoName m =
    [ [ match "messageName" [pWildCard] $
          "Data.Text.pack" @@ stringExp (T.unpack protoName)]
    , [ match "fieldsByTag" [] $
          let' (map (fieldDescriptorVarBind $ messageName m) $ fields)
              $ "Data.Map.fromList" @@ list fieldsByTag ]
    , [ match "unknownFields" [] $ rawFieldAccessor (unQual $ messageUnknownFields m) ]
    , [ match "defMessage" []
           $ recConstr (unQual $ messageName m) $
                  [ fieldUpdate (unQual $ haskellRecordFieldName $ plainFieldName f)
                        (hsFieldDefault syntaxType env (fieldDescriptor f))
                  | f <- messageFields m
                  ] ++
                  [ fieldUpdate (unQual $ haskellRecordFieldName $ oneofFieldName o)
                        "Prelude.Nothing"
                  | o <- messageOneofFields m
                  ] ++
                  [ fieldUpdate (unQual $ messageUnknownFields m)
                        "[]"]
      ]
    ]
  where
    fieldsByTag =
        [tuple
              [ t, fieldDescriptorVar f ]
              | f <- fields
              , let t = "Data.ProtoLens.Tag"
                          @@ litInt (fromIntegral
                                      $ fieldDescriptor f ^. number)
              ]
    fieldDescriptorVar = var . unQual . fieldDescriptorName
    fieldDescriptorName f
        = nameFromSymbol $ overloadedName (plainFieldName f) <> "__field_descriptor"
    fieldDescriptorVarBind n f
        = funBind
              [match (fieldDescriptorName f) []
                  $ fieldDescriptorExpr syntaxType env n f
              ]
    fields = messageFields m
                ++ (messageOneofFields m >>= fmap caseField . oneofCases)

-- | Get the name of the field when used in a text format proto. Groups are
-- special because their text format field name is the name of their type,
-- not the name of the field in the descriptor (e.g. "Foo", not "foo").
textFormatFieldName :: Env QName -> FieldDescriptorProto -> T.Text
textFormatFieldName env descr = case descr ^. type' of
    FieldDescriptorProto'TYPE_GROUP
        | Message msg <- definedFieldType descr env
              -> messageDescriptor msg ^. name
        | otherwise -> error $ "expected TYPE_GROUP for type name"
                           ++ T.unpack (descr ^. typeName)
    _ -> descr ^. name

fieldDescriptorExpr :: SyntaxType -> Env QName -> Name -> FieldInfo
                    -> Exp
fieldDescriptorExpr syntaxType env n f =
    ("Data.ProtoLens.FieldDescriptor"
        -- Record the original .proto name for text format
        @@ stringExp (T.unpack $ textFormatFieldName env fd)
        -- Force the type signature since it can't be inferred for Map entry
        -- types.
        @@ (fieldTypeDescriptorExpr (fd ^. type')
                @::@
                    ("Data.ProtoLens.FieldTypeDescriptor"
                        @@ hsFieldType env fd))
        @@ fieldAccessorExpr syntaxType env f)
    -- TODO: why is this type sig needed?
    @::@
    ("Data.ProtoLens.FieldDescriptor" @@ tyCon (unQual n))
  where
    fd = fieldDescriptor f

fieldAccessorExpr :: SyntaxType -> Env QName -> FieldInfo -> Exp
-- (PlainField Required foo), (OptionalField foo), etc...
fieldAccessorExpr syntaxType env f = accessorCon @@ lensOfExp hsFieldName

  where
    fd = fieldDescriptor f
    accessorCon = case fd ^. label of
          FieldDescriptorProto'LABEL_REQUIRED
              -> "Data.ProtoLens.PlainField" @@ "Data.ProtoLens.Required"
          FieldDescriptorProto'LABEL_OPTIONAL
              | isDefaultingOptional syntaxType fd
                  -> "Data.ProtoLens.PlainField" @@ "Data.ProtoLens.Optional"
              | otherwise -> "Data.ProtoLens.OptionalField"
          FieldDescriptorProto'LABEL_REPEATED
              | Just (k, v) <- getMapFields env fd
                  -> "Data.ProtoLens.MapField"
                         @@ lensOfExp (overloadedField k)
                         @@ lensOfExp (overloadedField v)
              | isPackedField syntaxType fd -> "Data.ProtoLens.PackedField"
              | otherwise -> "Data.ProtoLens.RepeatedField"
    hsFieldName
        = case fd ^. label of
              FieldDescriptorProto'LABEL_OPTIONAL
                  | not (isDefaultingOptional syntaxType fd)
                      -> "maybe'" <> overloadedField f
              _ -> overloadedField f

lensOfExp :: Symbol -> Exp
lensOfExp sym = ("Lens.Labels.lensOf'"
                  @@ ("Lens.Labels.proxy#" @::@
                      ("Lens.Labels.Proxy#" @@ promoteSymbol sym)))

overloadedField :: FieldInfo -> Symbol
overloadedField = overloadedName . plainFieldName

isDefaultingOptional :: SyntaxType -> FieldDescriptorProto -> Bool
isDefaultingOptional syntaxType f
    = f ^. label == FieldDescriptorProto'LABEL_OPTIONAL
          && syntaxType == Proto3
          && f ^. type' /= FieldDescriptorProto'TYPE_MESSAGE
          -- oneof fields have the same API as proto2 optional fields,
          -- but setting one field will automatically clear the others.
          && isNothing (f ^. maybe'oneofIndex)

isPackedField :: SyntaxType -> FieldDescriptorProto -> Bool
isPackedField s f = case f ^. options . maybe'packed of
    Just t -> t
    -- proto3 fields are packed by default.  Annoyingly, we need to
    -- implement this logic manually rather than relying on protoc.
    Nothing -> s == Proto3
                && f ^. type' `notElem`
                      [ FieldDescriptorProto'TYPE_MESSAGE
                      , FieldDescriptorProto'TYPE_GROUP
                      , FieldDescriptorProto'TYPE_STRING
                      , FieldDescriptorProto'TYPE_BYTES
                      ]

fieldTypeDescriptorExpr :: FieldDescriptorProto'Type -> Exp
fieldTypeDescriptorExpr = \case
    FieldDescriptorProto'TYPE_DOUBLE -> mk "ScalarField" "DoubleField"
    FieldDescriptorProto'TYPE_FLOAT -> mk "ScalarField" "FloatField"
    FieldDescriptorProto'TYPE_INT64 -> mk "ScalarField" "Int64Field"
    FieldDescriptorProto'TYPE_UINT64 -> mk "ScalarField" "UInt64Field"
    FieldDescriptorProto'TYPE_INT32 -> mk "ScalarField" "Int32Field"
    FieldDescriptorProto'TYPE_FIXED64 -> mk "ScalarField" "Fixed64Field"
    FieldDescriptorProto'TYPE_FIXED32 -> mk "ScalarField" "Fixed32Field"
    FieldDescriptorProto'TYPE_BOOL -> mk "ScalarField" "BoolField"
    FieldDescriptorProto'TYPE_STRING -> mk "ScalarField" "StringField"
    FieldDescriptorProto'TYPE_GROUP -> mk "MessageField" "GroupType"
    FieldDescriptorProto'TYPE_MESSAGE -> mk "MessageField" "MessageType"
    FieldDescriptorProto'TYPE_BYTES -> mk "ScalarField" "BytesField"
    FieldDescriptorProto'TYPE_UINT32 -> mk "ScalarField" "UInt32Field"
    FieldDescriptorProto'TYPE_ENUM -> mk "ScalarField" "EnumField"
    FieldDescriptorProto'TYPE_SFIXED32 -> mk "ScalarField" "SFixed32Field"
    FieldDescriptorProto'TYPE_SFIXED64 -> mk "ScalarField" "SFixed64Field"
    FieldDescriptorProto'TYPE_SINT32 -> mk "ScalarField" "SInt32Field"
    FieldDescriptorProto'TYPE_SINT64 -> mk "ScalarField" "SInt64Field"
  where
    mk x y = fromString ("Data.ProtoLens." ++ x)
              @@ fromString ("Data.ProtoLens." ++ y)

-- | Generate the implementation of NFData.rnf for the given message.
--
-- instance NFData Bar where
--    rnf = \x -> deepseq (_Bar'foo x) (deepseq (_Bar'bar x) ())
messageRnfExpr :: MessageInfo Name -> Exp
messageRnfExpr msg = lambda ["x__"] $ foldr (@@) "()" (map seqField fieldNames)
  where
    fieldNames = messageUnknownFields msg
                : map (haskellRecordFieldName . plainFieldName)
                       (messageFields msg)
                ++ map (haskellRecordFieldName . oneofFieldName)
                       (messageOneofFields msg)
    seqField :: Name -> Exp
    seqField f = "Control.DeepSeq.deepseq" @@ (var (unQual f) @@ "x__")

-- instance NFData Bar where
--   rnf (Foo'a x__) = rnf x__
--   rnf (Bar'b x__) = rnf x__
oneofRnfMatch :: OneofCase -> Match
oneofRnfMatch c = match "rnf" [unQual (caseConstructorName c) `pApp` ["x__"]]
                    $ "Control.DeepSeq.rnf" @@ "x__"
