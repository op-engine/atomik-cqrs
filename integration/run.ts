import { createDatabase } from './create-database';

const { databaseUrl } = await createDatabase();

// On macOS, libpq is keg-only and not in the default linker search path.
// Detect the Homebrew prefix and pass it to the Zig build if found.
const libpqPrefixResult = Bun.spawnSync(['brew', '--prefix', 'libpq']);
const libpqArgs =
  libpqPrefixResult.exitCode === 0
    ? [`-Dlibpq-prefix=${libpqPrefixResult.stdout.toString().trim()}`]
    : [];

const proc = Bun.spawn(
  ['zig', 'build', 'test-integration', ...libpqArgs, '--summary', 'all'],
  {
    cwd: new URL('..', import.meta.url).pathname,
    env: { ...process.env, ATOMIK_DATABASE_URL: databaseUrl },
    stdout: 'inherit',
    stderr: 'inherit',
  }
);

process.exit(await proc.exited);
