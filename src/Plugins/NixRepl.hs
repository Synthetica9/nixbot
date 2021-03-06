{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE NamedFieldPuns    #-}
{-# LANGUAGE OverloadedStrings #-}
module Plugins.NixRepl (nixreplPlugin) where

import           Config
import           NixEval
import           Plugins

import           Control.Applicative        ((<|>))
import           Control.Monad.Logger
import           Control.Monad.Reader
import           Control.Monad.State
import           Data.Aeson
import           Data.Bifunctor             (bimap)
import qualified Data.ByteString.Lazy.Char8 as BS
import           Data.List
import           Data.Text                  (pack)
import           GHC.Generics
import           IRC
import           System.Directory
import           System.FilePath
import qualified Text.Megaparsec            as P
import qualified Text.Megaparsec.Char       as C

import           Data.Map                   (Map)
import qualified Data.Map                   as M


data Instruction = Definition String String
                 | Evaluation String
                 | Command String [String]
                 deriving Show

data NixState = NixState
  { variables :: Map String String
  , scopes    :: [ String ]
  } deriving (Show, Read, Generic)

instance FromJSON NixState
instance ToJSON NixState

type Parser = P.Parsec () String

parser :: Parser Instruction
parser =
  P.try cmdParser <|> P.try defParser <|> Evaluation <$> (C.space *> P.takeRest)
    where
      literal :: Parser String
      literal = (:) <$> (C.letterChar <|> C.char '_') <*> P.many (C.alphaNumChar <|> C.char '_' <|> C.char '-' <|> C.char '\'')

      cmdParser :: Parser Instruction
      cmdParser = do
        C.space
        _ <- C.char ':'
        cmd <- literal
        args <- P.many (C.space *> P.some (P.anySingleBut ' '))
        C.space
        return $ Command cmd args

      defParser :: Parser Instruction
      defParser = do
        C.space
        lit <- literal
        C.space
        _ <- C.char '='
        C.space
        Definition lit <$> P.takeRest

nixFile :: NixState -> String -> String
nixFile NixState { variables, scopes } lit = "let\n"
    ++ concatMap (\(l, val) -> "\t" ++ l ++ " = " ++ val ++ ";\n") (M.assocs (M.union variables defaultVariables))
    ++ "in \n"
    ++ concatMap (\scope -> "\twith " ++ scope ++ ";\n") (reverse scopes)
    ++ "\t" ++ lit

nixEval :: (MonadReader Config m, MonadIO m) => String -> Bool -> m (Either String String)
nixEval contents eval = do
  nixPath <- reader nixPath'
  let nixInstPath = "/run/current-system/sw/bin/nix-instantiate"
  res <- liftIO $ nixInstantiate nixInstPath (defNixEvalOptions (Left (BS.pack contents)))
    { mode = if eval then Lazy else Parse
    , nixPath = nixPath
    , options = unsetNixOptions
      { allowImportFromDerivation = Just False
      , restrictEval = Just True
      , sandbox = Just True
      , showTrace = Just True
      }
    }
  return $ bimap (outputTransform . BS.unpack) (outputTransform . BS.unpack) res

tryMod :: (MonadReader Config m, MonadIO m, MonadState NixState m) => (NixState -> NixState) -> m (Maybe String)
tryMod modi = do
  newState <- gets modi
  let contents = nixFile newState "null"
  result <- nixEval contents False
  case result of
    Right _ -> do
      put newState
      return Nothing
    Left err -> return $ Just err

handle :: (MonadReader Config m, MonadIO m, MonadState NixState m) => Instruction -> m String
handle (Definition lit val) = do
  result <- tryMod (\s -> s { variables = M.insert lit val (variables s) })
  case result of
    Nothing  -> return $ lit ++ " defined"
    Just err -> return err
handle (Evaluation lit) = do
  st <- get
  let contents = nixFile st ("_show (\n" ++ lit ++ "\n)")
  result <- nixEval contents True
  case result of
    Right value -> return value
    Left err    -> return err
handle (Command "l" []) = return ":l needs an argument"
handle (Command "l" args) = do
  result <- tryMod (\s -> s { scopes = unwords args : scopes s } )
  case result of
    Nothing  -> return "imported scope"
    Just err -> return err
handle (Command "v" [var]) = do
  val <- gets $ M.findWithDefault (var ++ " is not defined") var . flip M.union defaultVariables . variables
  return $ var ++ " = " ++ val
handle (Command "v" _) = do
  vars <- gets $ M.keys . flip M.union defaultVariables . variables
  return $ "All bindings: " ++ unwords vars
handle (Command "s" _) = do
  scopes <- gets scopes
  return $ "All scopes: " ++ intercalate ", " scopes
--handle (Command "d" [lit]) = do
--  litDefined <- gets $ M.member lit . variables
--  if litDefined
--    then do
--      modify (\s -> s { variables = M.delete lit (variables s) })
--      return . Just $ "undefined " ++ lit
--    else return . Just $ lit ++ " is not defined"
--handle (Command "d" _) = return $ Just ":d takes a single argument"
handle (Command "r" []) = do
  modify (\s -> s { scopes = [] })
  return "Scopes got reset"
--handle (Command "r" ["v"]) = do
--  modify (\s -> s { variables = M.empty })
--  return $ Just "Variables got reset"
--handle (Command "r" _) = do
--  put $ NixState M.empty []
--  return $ Just "State got reset"
handle (Command cmd _) = return $ "Unknown command: " ++ cmd

defaultVariables :: Map String String
defaultVariables = M.fromList
  [ ("_show", "x: x")
  , ("pkgs", "import <nixpkgs> {}")
  , ("lib", "pkgs.lib")
  ]

nixreplPlugin :: Plugin
nixreplPlugin = Plugin
  { pluginName = "nixrepl"
  , pluginCatcher = \Input { inputUser, inputChannel, inputMessage } -> case inputMessage of
      '>':' ':nixString -> case P.runParser parser "(input)" nixString of
        Right instruction -> Consumed (inputUser, inputChannel, instruction)
        Left _            -> PassedOn
      _ -> PassedOn
  , pluginHandler = \(user, channel, instruction) -> do
      stateFile <- (</> "state") <$> case channel of
        Nothing -> getUserState user
        Just _  -> getGlobalState
      exists <- liftIO $ doesFileExist stateFile
      initialState <- if exists then
        liftIO (decodeFileStrict stateFile) >>= \case
          Just result -> return result
          Nothing -> do
            logErrorN $ "Failed to decode nix state at " <> pack stateFile
            return $ NixState M.empty []
      else
        return $ NixState M.empty []

      (result, newState) <- runStateT (handle instruction) initialState
      case channel of
        Nothing   -> privMsg user result
        Just chan -> chanMsg chan result
      liftIO $ encodeFile stateFile newState
  }
