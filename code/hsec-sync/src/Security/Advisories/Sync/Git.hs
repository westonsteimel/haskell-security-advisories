{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}

-- |
--
-- Helpers for deriving advisory metadata from a Git repo.
module Security.Advisories.Sync.Git
  ( GitDirectoryInfo (..),
    GitError (..),
    GitErrorCase (..),
    explainGitError,
    Repository (..),
    GitRepositoryEnsuredStatus (..),
    ensureGitRepositoryWithRemote,
    getDirectoryGitInfo,
    updateGitRepository,
    GitRepositoryStatus (..),
    gitRepositoryStatus,
  )
where

import Control.Monad (when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (runExceptT, throwE)
import Data.Time (ZonedTime)
import Data.Time.Format.ISO8601 (iso8601ParseM)
import qualified System.Directory as D
import System.Exit (ExitCode (ExitSuccess))
import System.Process (readProcessWithExitCode)

type Cmd = (FilePath, [String])

data GitError = GitError
  { gitCmd :: Cmd,
    gitError :: GitErrorCase
  }

runGit :: [String] -> IO (Cmd, ExitCode, String, String)
runGit args =
  (\(status, stdout, stderr) -> (("git", args), status, stdout, stderr))
    <$> readProcessWithExitCode "git" args ""

data GitErrorCase
  = -- | exit code, stdout and stderr
    GitProcessError ExitCode String String
  | -- | unable to parse this input as a datetime
    GitTimeParseError String
  deriving (Show)

explainGitError :: GitError -> String
explainGitError e =
  unlines
    [ "Called " <> show (fst $ gitCmd e) <> " with " <> show (snd $ gitCmd e),
      case gitError e of
        GitProcessError status stdout stderr ->
          unlines
            [ "git exited with status " <> show status,
              ">>> standard output:",
              stdout,
              ">>> standard error:",
              stderr
            ]
        GitTimeParseError s ->
          "failed to parse time: " <> s
    ]

data Repository = Repository
  { repositoryRoot :: FilePath,
    repositoryUrl :: String,
    repositoryBranch :: String
  }

data GitRepositoryStatus
  = GitDirectoryMissing
  | GitDirectoryEmpty
  | GitDirectoryInitialized

gitRepositoryStatus :: Repository -> IO GitRepositoryStatus
gitRepositoryStatus repo = do
  exists <- D.doesDirectoryExist $ repositoryRoot repo
  if exists
    then D.withCurrentDirectory (repositoryRoot repo) $ do
      (_, checkStatus, checkStdout, _) <-
        runGit ["rev-parse", "--is-inside-work-tree"]
      let out = filter (not . null) $ lines checkStdout
      case checkStatus of
        ExitSuccess
          | not (null out) && head out == "true" ->
              return GitDirectoryInitialized
        _ ->
          return GitDirectoryEmpty
    else return GitDirectoryMissing

data GitRepositoryEnsuredStatus
  = GitRepositoryCreated
  | GitRepositoryExisting

ensureGitRepositoryWithRemote ::
  Repository ->
  GitRepositoryStatus ->
  IO (Either GitError GitRepositoryEnsuredStatus)
ensureGitRepositoryWithRemote repo =
  \case
    GitDirectoryMissing ->
      clone
    GitDirectoryEmpty ->
      clone
    GitDirectoryInitialized ->
      return $ Right GitRepositoryExisting
  where
    clone = do
      (cmd, status, stdout, stderr) <-
        runGit ["clone", "-b", repositoryBranch repo, repositoryUrl repo, repositoryRoot repo]
      return $
        if status /= ExitSuccess
          then Left $ GitError cmd $ GitProcessError status stdout stderr
          else Right GitRepositoryCreated

updateGitRepository :: Repository -> IO (Either GitError ())
updateGitRepository repo =
  D.withCurrentDirectory (repositoryRoot repo) $
    runExceptT $ do
      _ <- liftIO $ runGit ["remote", "add", "origin", repositoryUrl repo] -- can fail if it exists
      (setUrlCmd, setUrlStatus, setUrlStdout, setUrlStderr) <-
        liftIO $ runGit ["remote", "set-url", "origin", repositoryUrl repo]
      when (setUrlStatus /= ExitSuccess) $
        throwE $
          GitError setUrlCmd $
            GitProcessError setUrlStatus setUrlStdout setUrlStderr

      (fetchAllCmd, fetchAllStatus, fetchAllStdout, fetchAllStderr) <-
        liftIO $ runGit ["fetch", "--all"]
      when (fetchAllStatus /= ExitSuccess) $
        throwE $
          GitError fetchAllCmd $
            GitProcessError fetchAllStatus fetchAllStdout fetchAllStderr

      (checkoutBranchCmd, checkoutBranchStatus, checkoutBranchStdout, checkoutBranchStderr) <-
        liftIO $ runGit ["checkout", repositoryBranch repo]
      when (checkoutBranchStatus /= ExitSuccess) $
        throwE $
          GitError checkoutBranchCmd $
            GitProcessError checkoutBranchStatus checkoutBranchStdout checkoutBranchStderr

      (resetCmd, resetStatus, resetStdout, resetStderr) <-
        liftIO $ runGit ["reset", "--hard", "origin/" <> repositoryBranch repo]

      when (resetStatus /= ExitSuccess) $
        throwE $
          GitError resetCmd $
            GitProcessError resetStatus resetStdout resetStderr

newtype GitDirectoryInfo = GitDirectoryInfo
  { lastModificationCommitDate :: ZonedTime
  }

getDirectoryGitInfo :: FilePath -> IO (Either GitError GitDirectoryInfo)
getDirectoryGitInfo path = do
  (cmd, status, stdout, stderr) <-
    runGit ["-C", path, "log", "--pretty=format:%cI", "--find-renames", "advisories"]
  let timestamps = filter (not . null) $ lines stdout
      onError = Left . GitError cmd
  case status of
    ExitSuccess
      | not (null timestamps) ->
          return $
            GitDirectoryInfo
              <$> parseTime onError (head timestamps)
    _ ->
      return $ onError $ GitProcessError status stdout stderr
  where
    parseTime onError s = maybe (onError $ GitTimeParseError s) Right $ iso8601ParseM s
