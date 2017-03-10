module Refurb.Store where

import ClassyPrelude
import Composite.Opaleye (defaultRecTable)
import Composite.Opaleye.TH (deriveOpaleyeEnum)
import Composite.TH (withProxies)
import Control.Arrow (returnA)
import Control.Lens (view)
import Control.Monad.Logger (MonadLogger, logDebug)
import Data.These (These(This, These, That))
import qualified Database.PostgreSQL.Simple as PG
import Frames ((:->), Record, rlens)
import Opaleye (Column, PGBool, PGInt4, PGFloat8, PGText, PGTimestamptz, QueryArr, Table(Table), asc, orderBy, queryTable, runQuery)
import Refurb.MigrationUtils (doesTableExist)
import Refurb.Types (Migration, migrationKey)

data MigrationResult
  = MigrationSuccess
  | MigrationFailure
  deriving (Eq, Show)

deriveOpaleyeEnum ''MigrationResult "migrationresult" (stripPrefix "migration" . toLower)

withProxies [d|
  type FId       = "id"       :-> Int32
  type FIdMay    = "id"       :-> Maybe Int32
  type CId       = "id"       :-> Column PGInt4
  type CIdMay    = "id"       :-> Maybe (Column PGInt4)
  type FKey      = "key"      :-> Text
  type CKey      = "key"      :-> Column PGText
  type FApplied  = "applied"  :-> UTCTime
  type CApplied  = "applied"  :-> Column PGTimestamptz
  type FOutput   = "output"   :-> Text
  type COutput   = "output"   :-> Column PGText
  type FResult   = "result"   :-> MigrationResult
  type CResult   = "result"   :-> Column PGMigrationResult
  type FDuration = "duration" :-> Double
  type CDuration = "duration" :-> Column PGFloat8

  type FProdSystem = "prodsystem" :-> Bool
  type CProdSystem = "prodsystem" :-> Column PGBool
  |]

type MigrationLog      = '[FId   , FKey, FApplied, FOutput, FResult, FDuration]
type MigrationLogW     = '[FIdMay, FKey, FApplied, FOutput, FResult, FDuration]
type MigrationLogColsR = '[CId   , CKey, CApplied, COutput, CResult, CDuration]
type MigrationLogColsW = '[CIdMay, CKey, CApplied, COutput, CResult, CDuration]

type RefurbConfig     = '[FProdSystem]
type RefurbConfigCols = '[CProdSystem]

migrationLog :: Table (Record MigrationLogColsW) (Record MigrationLogColsR)
migrationLog = Table "refurb_migration_log" defaultRecTable

refurbConfig :: Table (Record RefurbConfigCols) (Record RefurbConfigCols)
refurbConfig = Table "refurb_config" defaultRecTable

isSchemaPresent :: (MonadBaseControl IO m, MonadMask m, MonadLogger m) => PG.Connection -> m Bool
isSchemaPresent conn = do
  $logDebug "Checking if schema present"
  runReaderT (doesTableExist "refurb_config") conn

isProdSystem :: (MonadBaseControl IO m, MonadLogger m) => PG.Connection -> m Bool
isProdSystem conn = do
  $logDebug "Checking if this is a prod system"
  map (fromMaybe False . headMay) . liftBase . runQuery conn $ proc () -> do
    config <- queryTable refurbConfig -< ()
    returnA -< view (rlens cProdSystem) config

initializeSchema :: (MonadBaseControl IO m, MonadLogger m) => PG.Connection -> m ()
initializeSchema conn = do
  $logDebug "Initializing refurb schema"

  liftBase $ do
    void $ PG.execute_ conn "create type migrationresult as enum('success', 'failure')"
    void $ PG.execute_ conn "create table refurb_config (prodsystem boolean not null)"
    void $ PG.execute_ conn "insert into refurb_config (prodsystem) values (false)"
    void $ PG.execute_ conn "create sequence refurb_migration_log_serial"
    void $ PG.execute_ conn "\
      \create table refurb_migration_log (\
      \  id int not null primary key default nextval('refurb_migration_log_serial'),\
      \  key varchar not null unique,\
      \  applied timestamp with time zone not null,\
      \  output varchar not null,\
      \  result migrationresult not null,\
      \  duration double precision not null\
      \)"

readMigrationStatus
  :: (MonadBaseControl IO m, MonadLogger m)
  => PG.Connection
  -> [Migration]
  -> QueryArr (Record MigrationLogColsR) ()
  -> m [These Migration (Record MigrationLog)]
readMigrationStatus conn migrations restriction = do
  $logDebug "Reading migration status"
  migrationStatus <- liftBase $ runQuery conn . orderBy (asc $ view (rlens cKey)) $ proc () -> do
    mlog <- queryTable migrationLog -< ()
    restriction -< mlog
    returnA -< mlog

  let migrationLogByKey = mapFromList . map (view (rlens fKey) &&& id) $ migrationStatus

      alignMigration
        :: Migration
        -> ([These Migration (Record MigrationLog)], Map Text (Record MigrationLog))
        -> ([These Migration (Record MigrationLog)], Map Text (Record MigrationLog))
      alignMigration m@(view migrationKey -> k) (t, l) =
        first ((:t) . maybe (This m) (These m)) (updateLookupWithKey (\ _ _ -> Nothing) k l)

      (aligned, extra) = foldr alignMigration ([], migrationLogByKey) migrations

  pure $ map That (toList extra) ++ aligned

