-- |Utilities for writing migrations.
module Refurb.MigrationUtils where

import ClassyPrelude
import Control.Monad.Logger (logDebug)
import Data.Profunctor.Product.Default (Default)
import qualified Database.PostgreSQL.Simple as PG
import Database.PostgreSQL.Simple.ToRow (toRow)
import Database.PostgreSQL.Simple.Types (fromQuery)
import qualified Opaleye
import Refurb.Types (MonadMigration)

-- |Execute some parameterized SQL against the database connection.
-- Wraps 'PG.execute' using the 'MonadMigration' reader to get the connection.
execute :: (MonadMigration m, PG.ToRow q) => PG.Query -> q -> m Int64
execute q p = do
  conn <- ask
  $logDebug $ decodeUtf8 (fromQuery q) <> " with " <> tshow (toRow p)
  liftBase $ PG.execute conn q p

-- |Execute some parameterized SQL against the database connection.
-- Wraps 'PG.executeMany' using the 'MonadMigration' reader to get the connection.
executeMany :: (MonadMigration m, PG.ToRow q) => PG.Query -> [q] -> m Int64
executeMany q ps = do
  conn <- ask
  $logDebug $ decodeUtf8 (fromQuery q) <> " with ["
    <> maybe "" ((if length ps > 1 then (<> ", ...") else id) . tshow . toRow) (headMay ps) <> "]"
  liftBase $ PG.executeMany conn q ps

-- |Execute some fixed SQL against the database connection.
-- Wraps 'PG.execute_' using the 'MonadMigration' reader to get the connection.
execute_ :: MonadMigration m => PG.Query -> m Int64
execute_ q = do
  conn <- ask
  $logDebug . decodeUtf8 $ fromQuery q
  liftBase $ PG.execute_ conn q

-- |Run a parameterized query against the database connection.
-- Wraps 'PG.query' using the 'MonadMigration' reader to get the connection.
query :: (MonadMigration m, PG.ToRow q, PG.FromRow r) => PG.Query -> q -> m [r]
query q p = do
  conn <- ask
  $logDebug $ decodeUtf8 (fromQuery q) <> " with " <> tshow (toRow p)
  liftBase $ PG.query conn q p

-- |Run a fixed query against the database connection.
-- Wraps 'PG.query_' using the 'MonadMigration' reader to get the connection.
query_ :: (MonadMigration m, PG.FromRow r) => PG.Query -> m [r]
query_ q = do
  conn <- ask
  $logDebug . decodeUtf8 $ fromQuery q
  liftBase $ PG.query_ conn q

-- |Run an Opaleye query against the database connection.
-- Wraps 'Opaleye.runQuery' using the 'MonadMigration' reader to get the connection.
runQuery
  :: ( MonadMigration m
     , Default Opaleye.Unpackspec columns columns
     , Default Opaleye.QueryRunner columns haskells
     )
  => Opaleye.Query columns -> m [haskells]
runQuery q = do
  conn <- ask
  for_ (Opaleye.showSql q) ($logDebug . pack)
  liftBase $ Opaleye.runQuery conn q

-- |Check if a table exists using the @information_schema@ views.
doesTableExist :: MonadMigration m => Text -> m Bool
doesTableExist t =
  not . (null :: [PG.Only Int] -> Bool) <$> query "select 1 from information_schema.tables where table_name = ?" (PG.Only t)