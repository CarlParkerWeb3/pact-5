{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE GADTs #-}


module Pact.Core.Capabilities
 ( DefCapMeta(..)
 , DefManagedMeta(..)
 , CapForm(..)
 , capFormName
 , CapToken(..)
 , ctName, ctArgs
 , CapSlot(..)
 , csCap, csComposed
 , CapState(..)
 , csSlots, csManaged
 , csModuleAdmin, csAutonomous
 , ManagedCap(..)
 , mcCap, mcManaged, mcOriginalCap
 , ManagedCapType(..)
 , PactEvent(..)
 , dcMetaFqName
 ) where

import Control.Lens
import Control.DeepSeq
import Data.Text(Text)
import Data.Set(Set)
import GHC.Generics
import Data.Default


import Pact.Core.Pretty
import Pact.Core.Names
import Pact.Core.Hash

data DefManagedMeta name
  = DefManagedMeta (Int, Text) name
  | AutoManagedMeta
  deriving (Show, Functor, Foldable, Traversable, Eq)

data DefCapMeta name
  = DefEvent
  | DefManaged (DefManagedMeta name)
  | Unmanaged
  deriving (Show, Functor, Foldable, Traversable, Eq)


dcMetaFqName :: Traversal' (DefCapMeta (FQNameRef Name)) FullyQualifiedName
dcMetaFqName f = \case
  DefManaged (DefManagedMeta i (FQName fqn)) ->
    DefManaged . DefManagedMeta i . FQName <$> f fqn
  p -> pure p

data CapForm name e
  = WithCapability e e
  | CreateUserGuard name [e]
  deriving (Show, Functor, Foldable, Traversable, Eq, Generic)

instance (NFData name, NFData e) => NFData (CapForm name e)

capFormName :: Traversal (CapForm name e) (CapForm name' e) name name'
capFormName f = \case
  WithCapability e e' -> pure (WithCapability e e')
  CreateUserGuard name es -> (`CreateUserGuard` es) <$> f name

instance (Pretty name, Pretty e) => Pretty (CapForm name e) where
  pretty = \case
    WithCapability cap body ->
      parens ("with-capability" <+> parens (pretty cap <+> pretty body))
    CreateUserGuard name es ->
      parens ("create-user-guard" <+> parens (pretty name <+> hsep (pretty <$> es)))

-- | An acquired capability token
-- with the reference
data CapToken name v
  = CapToken
  { _ctName :: name
  , _ctArgs :: [v]
  } deriving (Show, Eq, Ord)

--
data CapSlot name v
 = CapSlot
 { _csCap :: CapToken name v
 , _csComposed :: [CapToken name v]
 } deriving (Show, Eq)

-- | The overall capability state
data CapState name v
  = CapState
  { _csSlots :: [CapSlot name v]
  , _csManaged :: Set (ManagedCap name v)
  , _csModuleAdmin :: Set ModuleName
  , _csAutonomous :: Set (CapToken name v)
  }
  deriving Show

instance (Ord name, Ord v) => Default (CapState name v) where
  def = CapState mempty mempty mempty mempty

-- Todo: Is there a reason why module + name is
-- an unqualified
data PactEvent v
  = PactEvent
  { _peName :: Text
  , _peArgs :: [v]
  , _peModule :: ModuleName
  , _peModuleHash :: ModuleHash
  } deriving (Show, Eq)

data ManagedCapType v
  = AutoManaged Bool
  | ManagedParam FullyQualifiedName v Int
  -- ^ managed cap, with manager function, managed value
  deriving Show

data ManagedCap name v
  = ManagedCap
  { _mcCap :: CapToken name v
  -- ^ The token without the managed param
  , _mcOriginalCap :: CapToken name v
  -- ^ The original, installed token
  , _mcManaged :: ManagedCapType v
  -- ^ Managed capability type
  } deriving (Show)

instance (Eq name, Eq v) => Eq (ManagedCap name v) where
  l == r = _mcCap l == _mcCap r

instance (Ord name, Ord v) => Ord (ManagedCap name v) where
  l `compare` r = _mcCap l `compare` _mcCap r

makeLenses ''CapState
makeLenses ''CapToken
makeLenses ''CapSlot
makeLenses ''ManagedCap



