// Offline Linux kernel-counter smoke; no model code, rights or VPS qualification.
const fs = require('node:fs');
const cp = require('node:child_process');
function counters() {
  const cpu = fs.readFileSync('/sys/fs/cgroup/cpu.stat', 'utf8').match(/^usage_usec (\d+)$/m);
  return {cpu_usage_usec: Number(cpu[1]), memory_peak_bytes: Number(fs.readFileSync('/sys/fs/cgroup/memory.peak', 'utf8'))};
}
const before = counters();
const grandchild = 'global.block = Buffer.alloc(32*1024*1024, 7); const end=Date.now()+200; while(Date.now()<end){}; process.stdout.write(String(block.length));';
const child = `global.block = Buffer.alloc(48*1024*1024, 9); require('node:child_process').execFileSync(process.execPath, ['-e', ${JSON.stringify(grandchild)}], {timeout: 10000}); process.stdout.write(String(block.length));`;
cp.execFileSync(process.execPath, ['-e', child], {timeout: 15000});
const after = counters();
if (after.cpu_usage_usec <= before.cpu_usage_usec + 100000 || after.memory_peak_bytes <= before.memory_peak_bytes + 32*1024*1024) {
  throw new Error('child/grandchild work absent from whole-tree kernel counters');
}
console.log(JSON.stringify({status:'functional_kernel_probe_passed', evidence_kind:'synthetic_functional',
  canonical_publication_enabled:false, target_qualification:'not_attested',
  membership:fs.readFileSync('/proc/self/cgroup','utf8'),
  mountinfo:fs.readFileSync('/proc/self/mountinfo','utf8').split('\n').filter(x=>x.includes(' - cgroup2 ')),
  remaining_pids:fs.readFileSync('/sys/fs/cgroup/cgroup.procs','utf8').trim(), before, after,
  cpu_seconds:(after.cpu_usage_usec-before.cpu_usage_usec)/1e6,
  memory_semantics:'kernel_cgroup_lifetime_charged_memory_peak'}, null, 2));
