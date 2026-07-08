import { instantPostgres } from 'neon-new';

export async function createDatabase() {
  const {
    databaseUrl,
    poolerUrl,
    claimUrl
  } = await instantPostgres({
    seed: {
      type: 'sql-script',
      path: './init.sql',
    }
  });

  return({ databaseUrl, poolerUrl , claimUrl });
}
