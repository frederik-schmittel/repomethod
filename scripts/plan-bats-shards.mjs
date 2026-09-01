#!/usr/bin/env node
import fs from 'node:fs';

function fail(message) {
  console.error(`[error] ${message}`);
  process.exit(1);
}

const [timingsPath, countRaw = '2'] = process.argv.slice(2);
const count = Number.parseInt(countRaw, 10);
if (!timingsPath || !Number.isInteger(count) || count < 1) fail('usage: plan-bats-shards.mjs <files.tsv> [shard-count]');

const lines = fs.readFileSync(timingsPath, 'utf8').trim().split('\n');
if (lines.shift() !== 'file\ttests\tfailures\terrors\tskipped\tseconds') fail('unexpected timing TSV header');
const rows = lines.filter(Boolean).map((line) => {
  const [file, , , , , secondsRaw] = line.split('\t');
  const seconds = Number(secondsRaw);
  if (!file || !Number.isFinite(seconds) || seconds < 0) fail(`invalid timing row: ${line}`);
  return { file: file.startsWith('tests/') ? file : `tests/${file}`, seconds };
});
if (rows.length < count) fail(`cannot create ${count} non-empty shards from ${rows.length} files`);

rows.sort((a, b) => b.seconds - a.seconds || a.file.localeCompare(b.file));
const shards = Array.from({ length: count }, (_, id) => ({ id, seconds: 0, files: [] }));
for (const row of rows) {
  shards.sort((a, b) => a.seconds - b.seconds || a.id - b.id);
  shards[0].files.push(row.file);
  shards[0].seconds += row.seconds;
}
shards.sort((a, b) => a.id - b.id);
console.log('# shard\tfile');
for (const shard of shards) {
  for (const file of shard.files.sort()) console.log(`${shard.id}\t${file}`);
}
console.error(shards.map((shard) => `shard ${shard.id}: ${shard.seconds.toFixed(3)}s`).join('\n'));
