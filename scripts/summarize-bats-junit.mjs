#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';

const [reportPath, filesOutputPath, testsOutputPath, ...expectedPaths] = process.argv.slice(2);

if (!reportPath || !filesOutputPath || !testsOutputPath || expectedPaths.length === 0) {
  console.error('usage: summarize-bats-junit.mjs <report.xml> <files.tsv> <tests.tsv> <test-file>...');
  process.exit(2);
}

const decodeXml = (value) => value
  .replaceAll('&quot;', '"')
  .replaceAll('&apos;', "'")
  .replaceAll('&lt;', '<')
  .replaceAll('&gt;', '>')
  .replaceAll('&amp;', '&');

const parseAttributes = (source) => {
  const attributes = new Map();
  const pattern = /([A-Za-z_:][A-Za-z0-9_.:-]*)="([^"]*)"/g;
  let match;
  while ((match = pattern.exec(source)) !== null) {
    attributes.set(match[1], decodeXml(match[2]));
  }
  return attributes;
};

const asNumber = (attributes, key) => {
  const value = Number(attributes.get(key) ?? '0');
  if (!Number.isFinite(value)) {
    throw new Error(`invalid numeric ${key}: ${attributes.get(key)}`);
  }
  return value;
};

if (!fs.existsSync(reportPath)) {
  throw new Error(`Bats JUnit report not found: ${reportPath}`);
}

const xml = fs.readFileSync(reportPath, 'utf8');
const expectedFiles = expectedPaths.map((file) => path.basename(file)).sort();
const expectedSet = new Set(expectedFiles);
const seenFiles = new Set();
const fileRows = [];
const testRows = [];

const suitePattern = /<testsuite\b([^>]*)>([\s\S]*?)<\/testsuite>/g;
let suiteMatch;
while ((suiteMatch = suitePattern.exec(xml)) !== null) {
  const suiteAttributes = parseAttributes(suiteMatch[1]);
  const file = suiteAttributes.get('name');
  if (!file) {
    throw new Error('JUnit testsuite is missing a name');
  }
  if (!expectedSet.has(file)) {
    throw new Error(`unexpected test file in JUnit report: ${file}`);
  }
  if (seenFiles.has(file)) {
    throw new Error(`duplicate test file in JUnit report: ${file}`);
  }
  seenFiles.add(file);

  const testcasePattern = /<testcase\b([^>]*?)(?:\/>|>([\s\S]*?)<\/testcase>)/g;
  let testcaseMatch;
  let testcaseCount = 0;
  let testcaseSeconds = 0;
  while ((testcaseMatch = testcasePattern.exec(suiteMatch[2])) !== null) {
    const testcaseAttributes = parseAttributes(testcaseMatch[1]);
    const testName = testcaseAttributes.get('name') ?? '<unnamed>';
    const seconds = asNumber(testcaseAttributes, 'time');
    testcaseCount += 1;
    testcaseSeconds += seconds;
    testRows.push([file, testName, seconds.toFixed(3)]);
  }

  const declaredTests = asNumber(suiteAttributes, 'tests');
  if (declaredTests !== testcaseCount) {
    throw new Error(`${file}: JUnit declares ${declaredTests} tests but contains ${testcaseCount} testcases`);
  }

  const suiteSeconds = suiteAttributes.has('time')
    ? asNumber(suiteAttributes, 'time')
    : testcaseSeconds;

  fileRows.push([
    file,
    String(testcaseCount),
    String(asNumber(suiteAttributes, 'failures')),
    String(asNumber(suiteAttributes, 'errors')),
    String(asNumber(suiteAttributes, 'skipped')),
    suiteSeconds.toFixed(3),
  ]);
}

const missingFiles = expectedFiles.filter((file) => !seenFiles.has(file));
if (missingFiles.length > 0) {
  throw new Error(`JUnit report omitted test files: ${missingFiles.join(', ')}`);
}

fileRows.sort((a, b) => a[0].localeCompare(b[0]));
testRows.sort((a, b) => a[0].localeCompare(b[0]) || a[1].localeCompare(b[1]));

const writeTsv = (outputPath, header, rows) => {
  const sanitize = (value) => String(value).replaceAll('\t', ' ').replaceAll('\r', ' ').replaceAll('\n', ' ');
  const lines = [header, ...rows.map((row) => row.map(sanitize).join('\t'))];
  fs.writeFileSync(outputPath, `${lines.join('\n')}\n`);
};

writeTsv(filesOutputPath, 'file\ttests\tfailures\terrors\tskipped\tseconds', fileRows);
writeTsv(testsOutputPath, 'file\ttest\tseconds', testRows);
