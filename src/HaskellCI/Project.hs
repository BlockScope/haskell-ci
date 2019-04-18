{-# LANGUAGE OverloadedLabels  #-}
{-# LANGUAGE OverloadedStrings #-}
-- | Handling of @cabal.project@ file
module HaskellCI.Project (
    Project (..),
    emptyProject,
    parseProjectFile,
    ) where

import           Data.ByteString                              (ByteString)
import           Data.Generics.Labels                         ()
import           GHC.Generics                                 (Generic)
import           Lens.Micro                                   (over)
import           System.Path                                  (Absolute, Path,
                                                               toFilePath)

import qualified Data.Map.Strict                              as M
import qualified Distribution.CabalSpecVersion                as C
import qualified Distribution.FieldGrammar                    as C
import qualified Distribution.Fields.Pretty                   as C
import qualified Distribution.PackageDescription.FieldGrammar as C
import qualified Distribution.Parsec.Common                   as C
import qualified Distribution.Parsec.Newtypes                 as C
import qualified Distribution.Parsec.Parser                   as C
import qualified Distribution.Parsec.ParseResult              as C
import qualified Distribution.Types.SourceRepo                as C

import           HaskellCI.Newtypes
import           HaskellCI.Optimization
import           HaskellCI.ParsecError

-- $setup
-- >>> :seti -XOverloadedStrings

data Project a = Project
    { prjPackages     :: [a]
    , prjConstraints  :: [String]
    , prjAllowNewer   :: [String]
    , prjReorderGoals :: Bool
    , prjMaxBackjumps :: Maybe Int
    , prjOptimization :: Optimization
    , prjSourceRepos  :: [C.SourceRepo]
    , prjOrigFields   :: [C.PrettyField]
    }
  deriving (Show, Functor, Foldable, Traversable, Generic)

emptyProject :: Project [a]
emptyProject = Project [] [] [] False Nothing OptimizationOn [] []

-- | Parse project file. Extracts only few fields.
--
-- >>> fmap prjPackages $ parseProjectFile "cabal.project" "packages: foo bar/*.cabal"
-- Right ["foo","bar/*.cabal"]
--
parseProjectFile :: Path Absolute -> ByteString -> Either String (Project String)
parseProjectFile fp bs = do
    fields0 <- either (Left . show) Right $ C.readFields bs
    let (fields1, sections) = C.partitionFields fields0
    let fields2 = M.filterWithKey (\k _ -> k `elem` knownFields) fields1
    case C.runParseResult $ parse fields0 fields2 sections of
        (_, Right x)       -> return x
        (ws, Left (_, es)) -> Left $ renderParseError (toFilePath fp) bs es ws
  where
    knownFields = C.fieldGrammarKnownFieldList $ grammar []

    parse origFields fields sections = do
        let prettyOrigFields = C.fromParsecFields $ filter notPackages origFields
        prj <- C.parseFieldGrammar C.cabalSpecLatest fields $ grammar prettyOrigFields
        foldr ($) prj <$> traverse parseSec (concat sections)

    parseSec :: C.Section C.Position -> C.ParseResult (Project String -> Project String)
    parseSec (C.MkSection (C.Name _pos name) [] fields) | name == "source-repository-package" = do
        let fields' = fst $ C.partitionFields fields
        repo <- C.parseFieldGrammar C.cabalSpecLatest fields' (C.sourceRepoFieldGrammar $ C.RepoKindUnknown "unused")
        return $ over #prjSourceRepos (repo :)

    parseSec _ = return id

notPackages :: C.Field ann -> Bool
notPackages (C.Field (C.Name _ "packages") _) = False
notPackages _                                 = True


grammar :: [C.PrettyField] -> C.ParsecFieldGrammar (Project String) (Project String)
grammar origFields = Project
    <$> C.monoidalFieldAla "packages"      (C.alaList' C.FSep PackageLocation) #prjPackages
    <*> C.monoidalFieldAla "constraints"   (C.alaList' C.CommaVCat NoCommas)   #prjConstraints
    <*> C.monoidalFieldAla "allow-newer"   (C.alaList' C.CommaVCat NoCommas)   #prjAllowNewer
    <*> C.booleanFieldDef  "reorder-goals"                                     #prjReorderGoals False
    <*> C.optionalFieldAla "max-backjumps" Int'                                    #prjMaxBackjumps
    <*> C.optionalFieldDef "optimization"                                      #prjOptimization OptimizationOn
    <*> pure []
    <*> pure origFields
