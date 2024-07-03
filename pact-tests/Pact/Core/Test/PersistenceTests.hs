-- | Tests of the SQLite persistence backend.

module Pact.Core.Test.PersistenceTests where

import Control.Monad.IO.Class (liftIO)
import Data.Default (Default, def)
import Data.IORef (newIORef)
import Data.Text (Text)
import qualified Data.Map as Map
import qualified Data.Set as Set
import Hedgehog (Gen, Property, (===), forAll, property)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.Hedgehog
import Test.Tasty.HUnit (assertEqual, testCase)
import qualified Hedgehog.Gen as Gen

import Pact.Core.Builtin
import Pact.Core.Environment
import Pact.Core.Guards
import Pact.Core.Gen
import Pact.Core.Literal
import Pact.Core.Names
import Pact.Core.PactValue
import qualified Pact.Core.PactValue as PactValue
import Pact.Core.Persistence.SQLite
import Pact.Core.Persistence
import Pact.Core.Persistence.MockPersistence
import Pact.Core.Repl.Compile
import Pact.Core.Repl.Utils
import Pact.Core.Serialise

-- | Top-level TestTree for Persistence Tests.
tests :: TestTree
tests = testGroup "Persistence"
  [ testGroup "CBOR encoding/decoding roundtrip" $
      testsWithSerial serialisePact coreBuiltinMap builtinGen (pure ())
  , sqliteRegression
  ]

getEvalEnv :: PactSerialise b i -> Map.Map Text b -> IO (EvalEnv b i)
getEvalEnv serial builtins = do
  pdb <- mockPactDb serial
  defaultEvalEnv pdb builtins

-- | Generate the test tree for any given `PactSerialise` serialization scheme,
-- given also a means of creating builtins and infos for that scheme.
testsWithSerial :: (Show i, Eq b, Eq i, Default i, IsBuiltin b)
  => PactSerialise b i
  -> Map.Map Text b
  -> Gen b
  -> Gen i
  -> [TestTree]
testsWithSerial serial builtins b i =
 [ testProperty "KeySet" $ keysetPersistRoundtrip serial builtins (keySetGen undefined)
   -- ^ keySetGen does not use its first argument now. We will pass a real argument
   --   once custom keyset predicate functions are supported.
 , testProperty "ModuleData" $ moduleDataRoundtrip serial builtins b i
 , testProperty "DefPactExec" $ defPactExecRoundtrip serial builtins b i
 , testProperty "Namespace" $ namespaceRoundtrip serial builtins
 ]

keysetPersistRoundtrip :: (Default i) => PactSerialise b i -> Map.Map Text b -> Gen KeySet -> Property
keysetPersistRoundtrip serial builtins keysetGen =
  property $ do
    keysetName <- forAll keySetNameGen
    keyset <- forAll keysetGen
    evalEnv <- liftIO $ getEvalEnv serial builtins
    writtenKeySetResult <- liftIO $ runEvalM (ExecEnv evalEnv) def  $ withSqlitePactDb serial ":memory:" $ \db -> do
      evalWrite def db Insert DKeySets keysetName keyset
      liftIO $ _pdbRead db DKeySets keysetName
    case writtenKeySetResult of
      (Left _, _) -> fail "Unexpected EvalM error"
      (Right writtenKeySet, _) -> Just keyset === writtenKeySet

moduleDataRoundtrip :: (Show i, Eq b, Eq i, Default i, IsBuiltin b) => PactSerialise b i -> Map.Map Text b -> Gen b -> Gen i -> Property
moduleDataRoundtrip serial builtins b i = property $ do
  moduleData <- forAll (moduleDataGen b i)
  moduleName <- forAll moduleNameGen
  evalEnv <- liftIO $ getEvalEnv serial builtins
  readResult <- liftIO $ runEvalM (ExecEnv evalEnv) def $ withSqlitePactDb serial ":memory:" $ \db -> do
    () <- evalWrite def db Insert DModules moduleName moduleData
    liftIO $ _pdbRead db DModules moduleName
  case readResult of
    (Left _, _) -> fail "Unexpected EvalM error"
    (Right writtenModuleData, _) ->
      Just moduleData === writtenModuleData

defPactExecRoundtrip :: (Default i) => PactSerialise b i -> Map.Map Text b -> Gen b -> Gen i -> Property
defPactExecRoundtrip serial builtins _b _i = property $ do
  defPactId <- forAll defPactIdGen
  defPactExec <- forAll (Gen.maybe defPactExecGen)
  evalEnv <- liftIO $ getEvalEnv serial builtins
  writeResult <- liftIO $ runEvalM (ExecEnv evalEnv) def $ withSqlitePactDb serial ":memory:" $ \db -> do
    () <- evalWrite def db Insert DDefPacts defPactId defPactExec
    liftIO $ _pdbRead db DDefPacts defPactId
  case writeResult of
    (Left _, _) -> fail "Unexpected EvalM error"
    (Right writtenDefPactExec, _) ->
      Just defPactExec === writtenDefPactExec

namespaceRoundtrip :: (Default i) => PactSerialise b i -> Map.Map Text b -> Property
namespaceRoundtrip serial builtins = property $ do
  ns <- forAll namespaceNameGen
  namespace <- forAll namespaceGen
  evalEnv <- liftIO $ getEvalEnv serial builtins
  writeResult <- liftIO $ runEvalM (ExecEnv evalEnv) def $ withSqlitePactDb serial ":memory:" $ \db -> do
    () <- evalWrite def db Insert DNamespaces ns namespace
    liftIO $ _pdbRead db DNamespaces ns
  case writeResult of
    (Left _, _) -> fail "Unexpected EvalM error"
    (Right writtenNamespace, _) ->
      Just namespace === writtenNamespace

-- | This regression test carries out a number of core operations on the
--   PactDb, including reading and writing Namespaces, KeySets, Modules, and
--   user data, within transactions. It ensures that TxLogs for transactions
--   contain the expected metadata.
sqliteRegression :: TestTree
sqliteRegression =
  testCase "sqlite persistence backend produces expected values/txlogs" $ do

    evalEnv <- liftIO $ getEvalEnv serialisePact_repl_spaninfo replBuiltinMap
    res <- liftIO $ runEvalM (ExecEnv evalEnv) def $ withSqlitePactDb serialisePact_repl_spaninfo ":memory:" $ \pdb -> do
      let
        user1 = "user1"
        usert = TableName user1 (ModuleName "someModule" Nothing)
      _txId1 <- liftIO $ _pdbBeginTx pdb Transactional
      evalCreateUserTable def pdb usert

      txs1 <- liftIO $ _pdbCommitTx pdb
      let
        rd = RowData $ Map.singleton (Field "utModule")
          (PObject $ Map.fromList
            [ (Field "namespace", PLiteral LUnit)
            , (Field "name", PString user1)
            ])
      rdEnc <- liftGasM def $ _encodeRowData serialisePact_repl_spaninfo rd
      liftIO $ assertEqual "output of commit" txs1 [ TxLog "SYS:usertables" "user1" rdEnc ]


      --  Begin tx
      t1 <- liftIO $ _pdbBeginTx pdb Transactional >>= \case
        Nothing -> error "expected txid"
        Just t -> pure t
      let
        row = RowData $ Map.fromList [(Field "gah", PactValue.PDecimal 123.454345)]
      rowEnc <- liftGasM def $ _encodeRowData serialisePact_repl_spaninfo row
      liftGasM def $ _pdbWrite pdb Insert (DUserTables usert) (RowKey "key1") row
      row' <- liftIO $ do
         _pdbRead pdb (DUserTables usert) (RowKey "key1") >>= \case
           Nothing -> error "expected row"
           Just r -> pure r
      liftIO $ assertEqual "row should be identical to its saved/recalled value" row row'

      let
        row2 = RowData $ Map.fromList
              [ (Field "gah", PactValue.PBool False)
              , (Field "fh", PactValue.PInteger 1)
              ]
      row2Enc <- liftGasM def $ _encodeRowData serialisePact_repl_spaninfo row2

      liftGasM def $ _pdbWrite pdb Update (DUserTables usert) (RowKey "key1") row2
      row2' <- liftIO $ _pdbRead pdb (DUserTables usert) (RowKey "key1") >>= \case
        Nothing -> error "expected row"
        Just r -> pure r
      liftIO $ assertEqual "user update should overwrite with new value" row2 row2'

      let
        ks = KeySet (Set.fromList [PublicKeyText "skdjhfskj"]) KeysAll
        ksEnc = _encodeKeySet serialisePact_repl_spaninfo ks
      _ <- liftGasM def $ _pdbWrite pdb Write DKeySets (KeySetName "ks1" Nothing) ks
      ks' <- liftIO $ _pdbRead pdb DKeySets (KeySetName "ks1" Nothing) >>= \case
        Nothing -> error "expected keyset"
        Just r -> pure r
      liftIO $ assertEqual "keyset should be equal after storage/retrieval" ks ks'


      -- module
      let mn = ModuleName "test" Nothing
      md <- liftIO loadModule
      let mdEnc = _encodeModuleData serialisePact_repl_spaninfo md
      liftGasM def $ _pdbWrite pdb Write DModules mn md

      md' <- liftIO $ _pdbRead pdb DModules mn >>= \case
        Nothing -> error "Expected module"
        Just r -> pure r
      liftIO $ assertEqual "module should be identical to its saved/recalled value" md md'

      txs2 <- liftIO $ _pdbCommitTx pdb
      liftIO $ assertEqual "output of commit" txs2
        [ TxLog "SYS:MODULES" "test" mdEnc
        , TxLog "SYS:KEYSETS" "ks1" ksEnc
        , TxLog "user1" "key1" row2Enc
        , TxLog "user1" "key1" rowEnc
        ]

      -- begin tx
      _ <- liftIO $ do
        _ <- _pdbBeginTx pdb Transactional
        tids <- _pdbTxIds pdb usert t1
        assertEqual "user txids" [TxId 1] tids

        txlog <- _pdbGetTxLog pdb usert (head tids)
        assertEqual "user txlog" txlog
          [ TxLog "USER_someModule_user1" "key1" (RowData $ Map.union (_unRowData row2) (_unRowData row))
          ]

      liftGasM def $ _pdbWrite pdb Insert (DUserTables usert) (RowKey "key2") row
      r1 <- liftIO $ _pdbRead pdb (DUserTables usert) (RowKey "key2") >>= \case
        Nothing -> error "expected row"
        Just r -> pure r
      liftIO $ assertEqual "user insert key2 pre-rollback" row r1

      liftIO $ do
        rkeys <- _pdbKeys pdb (DUserTables usert)
        liftIO $ assertEqual "keys pre-rollback [key1, key2]" [RowKey "key1", RowKey "key2"] rkeys

        _pdbRollbackTx pdb
        r2 <- _pdbRead pdb (DUserTables usert) (RowKey "key2")
        assertEqual "rollback erases key2" Nothing r2

        rkeys2 <- _pdbKeys pdb (DUserTables usert)
        assertEqual "keys post-rollback [key1]" [RowKey "key1"] rkeys2

    case res of
      (Left e, _) -> error $ "unexpected error" ++ show e
      (Right _, _) -> pure ()

    where
      loadModule = do
        let src = "(module test G (defcap G () true) (defun f (a: integer) 1))"
        pdb <- mockPactDb serialisePact_repl_spaninfo
        evalLog <- newIORef Nothing
        ee <- defaultEvalEnv pdb replBuiltinMap
        ref <- newIORef (ReplState mempty ee evalLog (SourceCode "" "") mempty mempty Nothing False)
        Right _ <- runReplT ref (interpretReplProgramBigStep (SourceCode "test" src) (const (pure ())))
        Just md <- _pdbRead pdb DModules (ModuleName "test" Nothing)
        pure md
