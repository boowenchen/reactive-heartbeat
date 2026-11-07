"""Temporarily break a safety property, require invariant failure, restore and retest."""
from pathlib import Path
import os, subprocess, hashlib
ROOT=Path(__file__).resolve().parents[1]
forge=str(Path.home()/'.foundry/bin/forge.exe') if os.name=='nt' else 'forge'
os.environ['SVM_HOME']=str(ROOT/'.toolchain/svm')
cases=[('heartbeat','src/Vault.sol','require(block.timestamp >= warnedAt + grace && block.timestamp >= resetAt + releaseAfter, "early");','/* MUTANT: time guard removed */','HeartbeatInvariantTest'),
       ('slipstream','src/Pool.sol','uint256 net = amount * 997;','uint256 net = amount * 1003;','PoolInvariantTest')]
cases = [c for c in cases if c[0] == 'heartbeat']
for project,file,old,new,suite in cases:
    base=ROOT;path=base/file;original=path.read_bytes();source=original.decode()
    if source.count(old)!=1: raise RuntimeError('Mutation target must be unique')
    logs=base/'test-results';logs.mkdir(exist_ok=True)
    try:
        path.write_text(source.replace(old,new),encoding='utf-8',newline='\n')
        result=subprocess.run([forge,'test','--root',str(base),'--match-contract',suite,'-vv'],capture_output=True,text=True,encoding='utf-8',errors='replace')
        (logs/'mutation-failed.txt').write_text(result.stdout+result.stderr,encoding='utf-8')
        if result.returncode==0 or '[FAIL' not in result.stdout or 'invariant_' not in result.stdout:
            raise RuntimeError('Mutation did not produce an invariant failure')
    finally:
        path.write_bytes(original)
    result=subprocess.run([forge,'test','--root',str(base),'-vv'],capture_output=True,text=True,encoding='utf-8',errors='replace')
    (logs/'restored-pass.txt').write_text(result.stdout+result.stderr,encoding='utf-8')
    if result.returncode: raise RuntimeError('Restored suite failed: '+result.stdout+result.stderr)
    (base/'TESTLOG.md').write_text(f'''# Test log

Local EVM tests, not testnet acceptance. Foundry 1.8.6; Solidity 0.8.30.
Run: `forge test -vv`. Stateful invariants: 128 runs x 64 calls; fuzz: 256 cases.

Mutation executed by `tools/mutation_check.py` in the build workspace:
- File: `{file}`
- Original: `{old}`
- Mutant: `{new}`
- Command: `forge test --match-contract {suite} -vv`
- Result: nonzero exit; invariant failed. [Raw failure](test-results/mutation-failed.txt).
- Original bytes restored; SHA256 `{hashlib.sha256(original).hexdigest()}`.
- Complete restored suite: exit 0. [Raw pass](test-results/restored-pass.txt).

The system caller is a local test double; these tests do not prove subscriptions,
signer delivery, gas billing, reorg handling or latency on the live network.
''',encoding='utf-8',newline='\n')
    print(project+': mutation killed; restored suite passes')
