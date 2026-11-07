// Docker-free pgTAP runner for the linked hosted dev project (bare --remote only).
// `supabase db query` returns only the last statement's rows, so each top-level
// `select ...` assertion in a test file is rewritten to `insert into _out ...`
// and the final `select * from finish();` is replaced by a summary query.
import { spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const dir = 'supabase/tests';
const helpers = existsSync(join(dir, 'helpers.sql')) ? readFileSync(join(dir, 'helpers.sql'), 'utf8') : '';
const files = readdirSync(dir).filter((f) => f.endsWith('.test.sql')).sort();
const tmp = mkdtempSync(join(tmpdir(), 'dbtest-'));
let failed = false;

for (const f of files) {
  const src = readFileSync(join(dir, f), 'utf8');
  const planned = Number(/select\s+plan\(\s*(\d+)\s*\)/i.exec(src)?.[1] ?? NaN);
  let sql = src
    .replace(/^select\s+plan\(.*$/im, (m) => `${m}\ncreate temp table _out(n serial, t text);`)
    .replace(/^select\s+(?!plan\(|\*\s+from\s+finish)/gim, 'insert into _out(t) select ')
    .replace(
      /^select\s+\*\s+from\s+finish\(\s*\)\s*;/im,
      `select (select count(*) from _out where t like 'ok%')::int as ok,
              (select count(*) from _out where t like 'not ok%')::int as bad,
              (select count(*) from _out)::int as total,
              (select coalesce(string_agg(t, E'\n' order by n), '') from _out where t like 'not ok%') as lines;`,
    );
  const tmpFile = join(tmp, f);
  writeFileSync(tmpFile, helpers ? `${helpers}\n${sql}` : sql);
  const r = spawnSync('npx', ['supabase', 'db', 'query', '--remote', '--yes', '-f', tmpFile], {
    encoding: 'utf8', shell: true,
  });
  const out = (r.stdout ?? '') + (r.stderr ?? '');
  let row;
  try {
    const json = out.slice(out.indexOf('{\n'), out.lastIndexOf('}') + 1);
    row = JSON.parse(json).rows?.[0];
  } catch { /* handled below */ }
  if (r.status !== 0 || !row || row.ok === undefined) {
    failed = true;
    console.log(`FAIL ${f} (error running SQL)`);
    console.log(out.trim());
    continue;
  }
  const good = row.bad === 0 && row.ok === planned && row.total === planned;
  if (good) {
    console.log(`PASS ${f} (${row.ok}/${planned})`);
  } else {
    failed = true;
    console.log(`FAIL ${f} (${row.ok}/${planned} ok, ${row.bad} not ok, ${row.total} run)`);
    if (row.lines) console.log(row.lines.replace(/\r/g, ''));
  }
}
rmSync(tmp, { recursive: true, force: true });
process.exit(failed ? 1 : 0);
