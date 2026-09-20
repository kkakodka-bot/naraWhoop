import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fixture, sourceFixture } from './sync-evidence-fixtures.mjs';
import { REQUIRED_MIGRATIONS } from './sync-evidence-contract.mjs';
import { PURE_DATA_SYMBOLS, SOURCE_ROOTS, checkKotlin, checkMigrations, checkSources } from './check-sync-sources.mjs';

test('exact reviewed pure symbol surface accepts explicit and aliased imports', () => {
  for (const name of PURE_DATA_SYMBOLS) {
    checkKotlin(`\t import com.noop.data.${name} as Alias; // test\n`, 'service/test.kt');
    checkKotlin(`import com . noop . data . ${name}\n`, 'service/main.kt');
  }
});
test('unknown data, Android, ingest and wildcards fail even in old exempt paths', () => {
  for (const name of ['WhoopDatabase', 'WhoopDao', 'WhoopRepository', 'DeviceRegistry', 'HrSampleExtra', 'NewUnknown', '*']) {
    for (const relative of ['service/main.kt', 'service/test.kt', 'scoring-service/analytics-kernel/src/main/kotlin/com/noop/data/Unsafe.kt']) {
      assert.throws(() => checkKotlin(` \timport com.noop.data.${name}\n`, relative), /forbidden import/);
    }
  }
  for (const symbol of ['android.os.Build', 'androidx.room.Dao', 'com.noop.ingest.Actor']) {
    assert.throws(() => checkKotlin(`import ${symbol} as Hidden\n`, 'fixture.kt'), /forbidden/);
  }
});
test('comments and string literals are not imports, nested comments preserve code following them', () => {
  checkKotlin('// import android.os.Build\n/* outer /* nested */ import androidx.room.Dao */\nval s = "import com.noop.data.*"\n', 'fixture.kt');
  assert.throws(() => checkKotlin('/* nested /* ok */ */\timport android.os.Build\n', 'fixture.kt'), /forbidden/);
  assert.throws(() => checkKotlin('/* unclosed', 'fixture.kt'), /unterminated/);
});
test('only exact existing Editor use may reference the JVM shim', () => {
  const reference = 'val editor: android.content.SharedPreferences.Editor? = null';
  checkKotlin(reference, 'scoring-service/analytics-kernel/build/synced-main/com/noop/analytics/Baselines.kt');
  assert.throws(() => checkKotlin(reference, 'service/Baselines.kt'), /qualified reference/);
  assert.throws(() => checkKotlin('val x = com.noop.data.WhoopDatabase.open()', 'fixture.kt'), /qualified reference/);
  assert.throws(() => checkKotlin('import android.content.SharedPreferences', 'scoring-service/analytics-kernel/src/main/kotlin/android/content/SharedPreferences.kt'), /forbidden/);
});
test('complete eight-ID source chain plus unrelated migrations passes', t => {
  const f = fixture(t); const directory = sourceFixture(f.directory);
  fs.writeFileSync(path.join(directory, '20260801000000_other.sql'), '-- unrelated\n');
  assert.equal(checkSources(f.directory).requiredMigrations, 8);
  assert.deepEqual(REQUIRED_MIGRATIONS, Array.from({ length: 8 }, (_, i) => `20260918${String(i + 1).padStart(2, '0')}0000`));
});
test('each missing ID, duplicate prefix and old base alone fail closed', t => {
  const f = fixture(t); const directory = sourceFixture(f.directory);
  for (const id of REQUIRED_MIGRATIONS) {
    const filename = path.join(directory, `${id}_synthetic.sql`);
    const bytes = fs.readFileSync(filename); fs.unlinkSync(filename);
    assert.throws(() => checkMigrations(f.directory), /exactly one/);
    fs.writeFileSync(filename, bytes);
    const duplicate = path.join(directory, `${id}_duplicate.sql`); fs.writeFileSync(duplicate, '-- duplicate');
    assert.throws(() => checkMigrations(f.directory), /exactly one/); fs.unlinkSync(duplicate);
  }
  for (const id of REQUIRED_MIGRATIONS) fs.unlinkSync(path.join(directory, `${id}_synthetic.sql`));
  assert.throws(() => checkMigrations(f.directory), /exactly one/);
});
test('empty, whitespace-only, unreadable and non-regular required migrations fail', t => {
  const f = fixture(t); const directory = sourceFixture(f.directory);
  const filename = path.join(directory, `${REQUIRED_MIGRATIONS[0]}_synthetic.sql`);
  for (const bytes of ['', ' \n\t']) {
    fs.writeFileSync(filename, bytes); assert.throws(() => checkMigrations(f.directory), /nonempty|empty/);
  }
  fs.writeFileSync(filename, '-- nonempty'); fs.chmodSync(filename, 0);
  assert.throws(() => checkMigrations(f.directory), /readable/); fs.chmodSync(filename, 0o600);
  fs.unlinkSync(filename); fs.mkdirSync(filename);
  assert.throws(() => checkMigrations(f.directory), /regular file/);
});
test('missing roots, unreadable Kotlin files and source symlinks fail closed', t => {
  const f = fixture(t); sourceFixture(f.directory);
  const filename = path.join(f.directory, SOURCE_ROOTS[0], 'Synthetic.kt');
  fs.chmodSync(filename, 0); assert.throws(() => checkSources(f.directory), /readable/); fs.chmodSync(filename, 0o600);
  fs.unlinkSync(filename); fs.symlinkSync(path.join(f.directory, 'synthetic.txt'), filename);
  assert.throws(() => checkSources(f.directory), /symlinks/); fs.unlinkSync(filename);
  fs.rmdirSync(path.dirname(filename)); assert.throws(() => checkSources(f.directory));
});
