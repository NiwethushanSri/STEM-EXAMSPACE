// Docker-free pgTAP runner for the linked hosted dev project (bare --remote only).
// Test files run unmodified except that the trailing `select * from finish(); rollback;`
// is replaced by an epilogue that reads pgTAP's own state (plan, tests run, failures)
// in one result query. `supabase db query` returns only the last statement's rows.
// helpers.sql (if present) is injected right after each file's first `begin;`.
import { spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const dir = process.env.DB_TEST_DIR || 'supabase/tests';
const helpersPath = join(dir, 'helpers.sql');
const helpers = existsSync(helpersPath) ? readFileSync(helpersPath, 'utf8') : '';
const files = existsSync(dir) ? readdirSync(dir).filter((f) => f.endsWith('.test.sql')).sort() : [];
if (files.length === 0) {
  console.log(`FAIL no *.test.sql files found in ${dir}`);
  process.exit(1);
}

const tmp = mkdtempSync(join(tmpdir(), 'dbtest-'));
let failed = false;

function run(sqlText, name) {
  const p = join(tmp, name);
  writeFileSync(p, sqlText);
  const r = spawnSync('npx', ['supabase', 'db', 'query', '--remote', '--yes', '-f', p], {
    encoding: 'utf8', shell: true,
  });
  const out = (r.stdout ?? '') + (r.stderr ?? '');
  let rows;
  try {
    rows = JSON.parse(out.slice(out.indexOf('{\n'), out.lastIndexOf('}') + 1)).rows;
  } catch { /* leave undefined */ }
  return { status: r.status, out, rows };
}

const epilogue = `
reset role;
select _get('plan') as planned, _get('curr_test') as ran, num_failed() as bad;
rollback;
`;

for (const f of files) {
  let src = readFileSync(join(dir, f), 'utf8');
  src = src.replace(/select\s+\*\s+from\s+finish\(\s*\)\s*;[\s\S]*$/i, '');
  if (helpers) src = src.replace(/\bbegin\s*;/i, (m) => `${m}\n${helpers}\n`);
  const r = run(src + epilogue, f);
  const row = r.rows?.[0];
  if (r.status !== 0 || !row || row.ran === undefined) {
    failed = true;
    console.log(`FAIL ${f} (SQL or CLI error)`);
    console.log(r.out.trim());
    continue;
  }
  const { planned, ran, bad } = row;
  if (planned != null && ran === planned && bad === 0) {
    console.log(`PASS ${f} (${ran - bad}/${planned})`);
    continue;
  }
  failed = true;
  console.log(`FAIL ${f} (planned ${planned ?? 'none'}, ran ${ran}, failed ${bad})`);
  if (bad > 0) {
    // Display only: re-run with assertions captured to name the failing ones.
    const detail = src
      .replace(/^(\s*select\s+plan\(.*)$/im, '$1\ncreate temp table _out(n serial, t text);')
      .replace(/^select\s+(?!plan\()/gim, 'insert into _out(t) select ');
    const d = run(detail + `\nreset role;\nselect coalesce(string_agg(t, E'\n' order by n), '') as lines from _out where t like 'not ok%';\nrollback;\n`, 'd-' + f);
    const lines = d.rows?.[0]?.lines;
    console.log(lines ? lines.replace(/\r/g, '') : '(failing assertion names unavailable; see failed count above)');
  }
}
rmSync(tmp, { recursive: true, force: true });
process.exit(failed ? 1 : 0);
