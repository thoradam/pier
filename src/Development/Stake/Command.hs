-- | A generic approach to building and caching outputs hermetically.
--
-- Output format: .stake/artifact/HASH/path/to/files
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TypeOperators #-}
module Development.Stake.Command
    ( commandRules
    , Output
    , output
    , prog
    , progA
    , progTemp
    , input
    , inputs
    , inputList
    , message
    , withCwd
    , runCommand
    , runCommandStdout
    , runCommand_
    , Command
    , Artifact
    , externalFile
    , (/>)
    , relPath
    , replaceArtifactExtension
    , readArtifact
    , readArtifactB
    , doesArtifactExist
    , writeArtifact
    , matchArtifactGlob
    , unfreezeArtifacts
    , copyArtifact
    , callArtifact
    ) where

import Crypto.Hash.SHA256
import Control.Monad (forM_, when, unless)
import Control.Monad.IO.Class
import qualified Data.ByteString as B
import Data.ByteString.Base64
import qualified Data.ByteString.Char8 as BC
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Set (Set)
import Data.Semigroup
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import Development.Shake
import Development.Shake.Classes hiding (hash)
import Development.Shake.FilePath
import GHC.Generics
import System.Directory as Directory
import System.IO.Temp
import System.Process (showCommandForUser)
import System.Posix.Files (createSymbolicLink)
import Distribution.Simple.Utils (matchDirFileGlob)

import Development.Stake.Core
import Development.Stake.Orphans ()
import Development.Stake.Persistent

-- TODO: reconsider names in this module

data Command = Command
    { _commandProgs :: [Prog]
    , commandInputs :: Set Artifact
    }
    deriving (Show, Typeable, Eq, Generic)
instance Hashable Command
instance Binary Command
instance NFData Command

data Call
    = CallEnv String -- picked up from $PATH
    | CallArtifact Artifact
    | CallTemp FilePath -- Local file to this Command
                        -- (e.g. generated by an earlier call)
                        -- (This is a hack around stake which tries to resolve
                        -- local files in the env.  Consider getting rid of it
                        -- if we make the GHC configure step more hermetic.)
    deriving (Show, Typeable, Eq, Generic)
instance Hashable Call
instance Binary Call
instance NFData Call

data Prog
    = Prog { progCall :: Call
           , progArgs :: [String]
           , progCwd :: FilePath  -- relative to the root of the sandbox
           }
    | Message String
    deriving (Typeable, Eq, Generic)
instance Hashable Prog
instance Binary Prog
instance NFData Prog

instance Show Prog where
    show (Message s) = "(Message " ++ show s ++ ")"
    show p@Prog{} = "(" ++ maybeCd
                ++ showCommandForUser (showCall $ progCall p) (progArgs p) ++ ")"
      where
        maybeCd
            | progCwd p == "." = ""
            | otherwise = "cd " ++ show (progCwd p) ++ " && "
        showCall (CallArtifact a) = artifactRealPath a
        -- TODO: this doesn't fully distinguish env and temp...
        showCall (CallEnv f) = f
        showCall (CallTemp f) = f
    showList [] = id
    showList (p:ps) = shows p . showString " && " . showList ps

instance Monoid Command where
    Command ps is `mappend` Command ps' is' = Command (ps ++ ps') (is <> is')
    mempty = Command [] Set.empty

instance Semigroup Command

-- TODO: allow prog taking Artifact and using it as input

prog :: String -> [String] -> Command
prog p as = Command [Prog (CallEnv p) as "."] Set.empty

progA :: Artifact -> [String] -> Command
progA p as = Command [Prog (CallArtifact p) as "."] (Set.singleton p)

progTemp :: FilePath -> [String] -> Command
progTemp p as = Command [Prog (CallTemp p) as "."] Set.empty

message :: String -> Command
message s = Command [Message s] Set.empty

withCwd :: FilePath -> Command -> Command
withCwd path (Command ps as)
    | isAbsolute path = error $ "withCwd: expected relative path, got " ++ show path
    | otherwise = Command (map setPath ps) as
  where
    setPath m@Message{} = m
    setPath p = p { progCwd = path }

input :: Artifact -> Command
input = inputs . Set.singleton

inputList :: [Artifact] -> Command
inputList = inputs . Set.fromList

inputs :: Set Artifact -> Command
inputs = Command []

-- | TODO: figure out more light-weight ways of achieving the same effect
copyArtifact :: Artifact -> FilePath -> Command
copyArtifact src dest
    | isAbsolute dest
        = error $ "copyArtifact: requires relative destination, found " ++ show dest
    | otherwise =   prog "mkdir" ["-p", takeDirectory dest]
                    -- TODO: first remove if it already exists?
                    <> prog "cp" ["-pRL", relPath src, dest]
                    -- Unfreeze the files so they can be modified by later calls within
                    -- the same `runCommand`
                    <> prog "chmod" ["-R", "u+w", dest]
                    <> input src

data Output a = Output [FilePath] (Hash -> a)

instance Functor Output where
    fmap f (Output g h) = Output g (f . h)

instance Applicative Output where
    pure = Output [] . const
    Output f g <*> Output f' g' = Output (f ++ f') (g <*> g')

output :: FilePath -> Output Artifact
output f = Output [f] $ flip Artifact (normalise f) . Built

-- | Unique identifier of a command
newtype Hash = Hash B.ByteString
    deriving (Show, Eq, Ord, Binary, NFData, Hashable, Generic)

makeHash :: String -> Hash
makeHash = Hash . fixBase64Path . encode . hash . T.encodeUtf8 . T.pack
  where
    -- Remove slashes, since the strings will appear in filepaths.
    -- Also remove some other characters to reduce shell errors.
    fixBase64Path = BC.map $ \case
                                '/' -> '-'
                                '+' -> '.'
                                '=' -> '_'
                                c -> c

hashDir :: Hash -> FilePath
hashDir h = artifactDir </> hashString h

artifactDir :: FilePath
artifactDir = stakeFile "artifact"

hashString :: Hash -> String
hashString (Hash h) = BC.unpack h

data Artifact = Artifact Source FilePath
    deriving (Eq, Ord, Generic)

instance Show Artifact where
    show (Artifact External f) = show f
    show (Artifact (Built h) f) = hashString h ++ ":" ++ show f

instance Hashable Artifact
instance Binary Artifact
instance NFData Artifact

data Source = Built Hash | External
    deriving (Show, Eq, Ord, Generic)

instance Hashable Source
instance Binary Source
instance NFData Source

externalFile :: FilePath -> Artifact
externalFile = Artifact External . normalise

(/>) :: Artifact -> FilePath -> Artifact
Artifact source f /> g = Artifact source $ normalise $ f </> g

-- TODO: go back to </> for artifacts (or some one-sided operator),
-- and add a check that no two inputs for the same Command are
-- subdirs of each other

data CommandQ = CommandQ
    { commandQCmd :: Command
    , _commandQOutputs :: [FilePath]
    }
    deriving (Show, Eq, Generic)

instance Hashable CommandQ
instance Binary CommandQ
instance NFData CommandQ

type instance RuleResult CommandQ = Hash

-- TODO: sanity-check filepaths; for example, normalize, should be relative, no
-- "..", etc.
commandHash :: CommandQ -> Action Hash
commandHash cmdQ = do
    let externalFiles = [f | Artifact External f <- Set.toList $ commandInputs
                                                        $ commandQCmd cmdQ]
    need externalFiles
    -- TODO: streaming hash
    userFileHashes <- liftIO $ map hash <$> mapM B.readFile externalFiles
    return . makeHash
        $ "commandHash: " ++ show (cmdQ, userFileHashes)

runCommand :: Output t -> Command -> Action t
runCommand (Output outs mk) c
    = mk <$> askPersistent (CommandQ c outs)

runCommandStdout :: Command -> Action String
runCommandStdout c = do
    out <- runCommand (output stdoutPath) c
    liftIO $ readFile $ artifactRealPath out

runCommand_ :: Command -> Action ()
runCommand_ = runCommand (pure ())

-- TODO: come up with a better story around cleaning/rebuilds.
-- (See also comments about removing the directory in `commandRules`.)
-- Maybe: don't use Persistent; instead, just look for the hash to be present
-- to decide whether to re-run things (similar to how oracles work).

-- TODO: make sure no artifact is a subdir of another artifact.

-- TODO: directories within archives are writable, and are modifyable
-- through symlinks.  Either just always do a `lndir`, or use real
-- sandboxes.

commandRules :: Rules ()
commandRules = addPersistent $ \cmdQ@(CommandQ (Command progs inps) outs) -> do
    h <- commandHash cmdQ
    let outDir = hashDir h
    -- Skip if the output directory already exists; we'll produce it atomically
    -- below.  This could happen if the action stops before Shake registers it as
    -- complete, due to either a synchronous or asynchronous exception.
    exists <- liftIO $ Directory.doesDirectoryExist outDir
    unless exists $ do
        tmp <- liftIO $ getCanonicalTemporaryDirectory >>= flip createTempDirectory
                                                        (hashString h)
        liftIO $ collectInputs inps tmp
        mapM_ (createParentIfMissing . (tmp </>)) outs
        let unStdout (Stdout out) = out
        -- TODO: more flexibility around the env vars
        -- Also: limit valid parameters for the *prog* binary (rather than taking it
        -- from the PATH that the `stake` executable sees).
        let run (Message s) = putNormal s >> return B.empty
            run (Prog p as cwd) = do
                    -- hack around shake weirdness w.r.t. relative binary paths
                    let p' = case p of
                                CallEnv s -> s
                                CallArtifact f -> tmp </> relPath f
                                CallTemp f -> tmp </> f
                    quietly $ unStdout
                            <$> command [Cwd $ tmp </> cwd, Env defaultEnv]
                                    p' (map (spliceTempDir tmp) as)
        out <- B.concat <$> mapM run progs
        liftIO $ B.writeFile (tmp </> stdoutPath) out
        liftIO $ forM_ outs $ \f -> do
                        exist <- Directory.doesPathExist (tmp </> f)
                        unless exist $
                            error $ "runCommand: missing output "
                                    ++ show f
        liftIO $ withSystemTempDirectory (hashString h) $ \tempOutDir -> do
            mapM_ (createParentIfMissing . (tempOutDir </>)) outs
            mapM_ (\f -> renameAndFreezeFile (tmp </> f) (tempOutDir </> f)) outs
            createParentIfMissing outDir
            -- Make the output directory appear atomically (see above).
            Directory.renameDirectory tempOutDir outDir
        -- Clean up the temp directory, but only if the above commands succeeded.
        liftIO $ removeDirectoryRecursive tmp
    return h

-- TODO: more hermetic?
collectInputs :: Set Artifact -> FilePath -> IO ()
collectInputs inps tmp = do
    let inps' = dedupArtifacts inps
    checkAllDistinctPaths inps'
    liftIO $ mapM_ (linkArtifact tmp) inps'

stdoutPath :: FilePath
stdoutPath = ".stdout"

defaultEnv :: [(String, String)]
defaultEnv = [("PATH", "/usr/bin:/bin")]

spliceTempDir :: FilePath -> String -> String
spliceTempDir tmp = T.unpack . T.replace (T.pack "${TMPDIR}") (T.pack tmp) . T.pack

checkAllDistinctPaths :: Monad m => [Artifact] -> m ()
checkAllDistinctPaths as =
    case Map.keys . Map.filter (> 1) . Map.fromListWith (+)
            . map (\a -> (relPath a, 1 :: Integer)) $ as of
        [] -> return ()
        -- TODO: nicer error, telling where they came from:
        fs -> error $ "Artifacts generated from more than one command: " ++ show fs

-- Remove duplicate artifacts that are both outputs of the same command, and where
-- one is a subdirectory of the other (for example, constructed via `/>`).
dedupArtifacts :: Set Artifact -> [Artifact]
dedupArtifacts = loop . Set.toAscList
  where
    -- Loop over artifacts built from the same command.
    -- toAscList plus lexicographic sorting means that
    -- subdirectories with the same hash will appear consecutively after directories
    -- that contain them.
    loop (a@(Artifact (Built h) f) : Artifact (Built h') f' : fs)
        | h == h', (f <//> "*") ?== f' = loop (a:fs)
    loop (f:fs) = f : loop fs
    loop [] = []

renameAndFreezeFile :: FilePath -> FilePath -> IO ()
renameAndFreezeFile src dest = do
    renamePath src dest
    let freeze f = getPermissions f >>= setPermissions f . setOwnerWritable False
    forFileRecursive_ freeze dest

-- | Make all artifacts user-writable, so they can be deleted by `clean-all`.
unfreezeArtifacts :: IO ()
unfreezeArtifacts = do
    exists <- Directory.doesDirectoryExist artifactDir
    when exists $ forFileRecursive_ unfreeze artifactDir
  where
    unfreeze f = getPermissions f >>= setPermissions f . setOwnerWritable True

-- TODO: don't loop on symlinks, and be more efficient?
forFileRecursive_ :: (FilePath -> IO ()) -> FilePath -> IO ()
forFileRecursive_ act f = do
    isDir <- Directory.doesDirectoryExist f
    if not isDir
        then act f
        else do
            fs <- filter (not . specialFile) <$> Directory.getDirectoryContents f
            mapM_ (forFileRecursive_ act . (f </>)) fs
            act f
  where
    specialFile "." = True
    specialFile ".." = True
    specialFile _ = False

-- Symlink the artifact into the given destination directory.
-- If the artifact is itself a directory, make a separate symlink
-- for each file (similar to `lndir`).
-- TODO: this could stand to be optimized; it takes about 10% of the time for
-- building "lens" (not including downloads).
linkArtifact :: FilePath -> Artifact -> IO ()
linkArtifact _ (Artifact External f)
    | isAbsolute f = return ()
linkArtifact dir a = do
    curDir <- getCurrentDirectory
    let realPath = curDir </> artifactRealPath a
    let localPath = dir </> relPath a
    checkExists realPath
    createParentIfMissing localPath
    createSymbolicLink realPath localPath
  where
    -- Sanity check
    checkExists f = do
        isFile <- Directory.doesFileExist f
        isDir <- Directory.doesDirectoryExist f
        when (not isFile && not isDir) $ error $ "linkArtifact: source does not exist: " ++ show f


-- TODO: use permissions and/or sandboxing to make this more robust
artifactRealPath :: Artifact -> FilePath
artifactRealPath (Artifact External f) = f
artifactRealPath (Artifact (Built h) f) = hashDir h </> f

replaceArtifactExtension :: Artifact -> String -> Artifact
replaceArtifactExtension (Artifact s f) ext
    = Artifact s $ replaceExtension f ext

readArtifact :: Artifact -> Action String
readArtifact (Artifact External f) = readFile' f -- includes need
readArtifact f = liftIO $ readFile $ artifactRealPath f

readArtifactB :: Artifact -> Action B.ByteString
readArtifactB (Artifact External f) = need [f] >> liftIO (B.readFile f)
readArtifactB f = liftIO $ B.readFile $ artifactRealPath f

-- NOTE: relPath may actually be an absolute path, if it was created from
-- externalFile called on an absolute path.
-- TODO: rename?
relPath :: Artifact -> FilePath
relPath (Artifact _ f) = f

writeArtifact :: MonadIO m => FilePath -> String -> m Artifact
writeArtifact path contents = liftIO $ do
    let h = makeHash $ "writeArtifact: " ++ contents
    let dir = hashDir h
    -- TODO: remove if it already exists?  Should this be Action?
    createParentIfMissing (dir </> path)
    writeFile (dir </> path) contents
    return $ Artifact (Built h) $ normalise path

-- I guess we need doesFileExist?  Can we make that robust?
doesArtifactExist :: Artifact -> Action Bool
doesArtifactExist (Artifact External f) = Development.Shake.doesFileExist f
doesArtifactExist f = liftIO $ Directory.doesFileExist (artifactRealPath f)

matchArtifactGlob :: Artifact -> FilePath -> Action [Artifact]
-- TODO: match the behavior of Cabal
matchArtifactGlob (Artifact External f) g
    = map (Artifact External . normalise . (f </>)) <$> getDirectoryFiles f [g]
matchArtifactGlob a@(Artifact (Built h) f) g
    = fmap (map (Artifact (Built h) . normalise . (f </>)))
            $ liftIO $ matchDirFileGlob (artifactRealPath a) g

-- TODO: merge more with above code?  How hermetic should it be?
callArtifact :: Set Artifact -> Artifact -> [String] -> IO ()
callArtifact inps bin args = do
    tmp <- liftIO $ getCanonicalTemporaryDirectory >>= flip createTempDirectory
                                                        "exec"
    -- TODO: preserve if it fails?  Make that a parameter?
    collectInputs (Set.insert bin inps) tmp
    cmd_ [Cwd tmp]
        (tmp </> relPath bin) args
    -- Clean up the temp directory, but only if the above commands succeeded.
    liftIO $ removeDirectoryRecursive tmp
