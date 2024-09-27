{-# LANGUAGE ImportQualifiedPost #-}
-- | 

module Pact.Core.Command.Server.History
  ( HistoryDb(..)
  , withHistoryDb
  , unsafeCreateHistoryDb
  , unsafeCloseHistoryDb
  , commandFromStableEncoding
  , commandToStableEncoding )
where

import Data.Text qualified as T
import Control.Exception.Safe
import Control.Monad.IO.Class (MonadIO, liftIO)
import qualified Database.SQLite3 as SQL
import qualified Database.SQLite3.Direct as Direct

import Pact.Core.Command.Types
import Pact.Core.Hash
import Pact.Core.Errors
import Pact.Core.Evaluate

import qualified Pact.JSON.Encode as J
import qualified Pact.JSON.Decode as J

import Pact.Core.StableEncoding


commandToStableEncoding
  :: CommandResult Hash (PactErrorCompat Info)
  -> CommandResult Hash (PactErrorCompat (StableEncoding Info))
commandToStableEncoding m = CommandResult
      { _crReqKey = _crReqKey m
      , _crTxId = _crTxId m
      , _crResult = (fmap.fmap) StableEncoding (_crResult m)
      , _crGas = _crGas m
      , _crLogs = _crLogs m
      , _crContinuation = _crContinuation m
      , _crMetaData = _crMetaData m
      , _crEvents = _crEvents m
      }

commandFromStableEncoding
  :: CommandResult Hash (PactErrorCompat (StableEncoding Info))
  -> CommandResult Hash (PactErrorCompat Info)
commandFromStableEncoding m = CommandResult
      { _crReqKey = _crReqKey m
      , _crTxId = _crTxId m
      , _crResult = (fmap.fmap) _stableEncoding (_crResult m)
      , _crGas = _crGas m
      , _crLogs = _crLogs m
      , _crContinuation = _crContinuation m
      , _crMetaData = _crMetaData m
      , _crEvents = _crEvents m
      }


type Cmd = CommandResult Hash (PactErrorCompat Info)

data HistoryDb
  = HistoryDb
  { _histDbInsert :: RequestKey -> Cmd -> IO (Either SomeException ())
  , _histDbRead   :: RequestKey -> IO (Maybe Cmd)
  }

withHistoryDb
  :: (MonadMask m, MonadIO m)
  => T.Text
  -> (HistoryDb -> m a)
  -> m a
withHistoryDb conStr act = bracket open close (act . dbToHistDb)
  where
    open = liftIO $ do
      db <- SQL.open conStr
      SQL.exec db createHistoryTblStmt
      pure db
    close = liftIO . SQL.close

unsafeCreateHistoryDb :: T.Text -> IO (HistoryDb, Direct.Database)
unsafeCreateHistoryDb  conStr = do
  db <- SQL.open conStr
  SQL.exec db createHistoryTblStmt
  pure $ (dbToHistDb db, db)

unsafeCloseHistoryDb :: Direct.Database -> IO ()
unsafeCloseHistoryDb = SQL.close

dbToHistDb :: Direct.Database -> HistoryDb
dbToHistDb db = HistoryDb
  { _histDbInsert = \(RequestKey h) cmd -> try $! SQL.withStatement db "INSERT INTO \"SYS:PactServiceHistory\" (reqkey, cmddata) values (?,?)" $ \stmt -> do
      SQL.bind stmt [ SQL.SQLText $ hashToText h
                    , SQL.SQLBlob $ J.encodeStrict $ commandToStableEncoding cmd]
      SQL.stepNoCB stmt >> pure ()
  , _histDbRead = \(RequestKey h) -> SQL.withStatement db "SELECT cmddata from \"SYS:PactServiceHistory\" where reqkey = ? LIMIT 1" $ \stmt -> do
      SQL.bind stmt [SQL.SQLText $ hashToText h]
      SQL.stepNoCB stmt >>= \case
        SQL.Done -> pure Nothing
        SQL.Row -> do
          [SQL.SQLBlob value] <- SQL.columns stmt
          pure $ commandFromStableEncoding <$> J.decodeStrict value
  }


createHistoryTblStmt :: T.Text
createHistoryTblStmt
  = "CREATE TABLE IF NOT EXISTS \"SYS:PactServiceHistory\" \
    \ (reqkey TEXT PRIMARY KEY, \
    \  cmddata BLOB)"
