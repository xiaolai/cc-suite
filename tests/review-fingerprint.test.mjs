import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, rmSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';
import { reviewFingerprint } from '../scripts/lib/review-fingerprint.mjs';
test('review identity changes for tracked, staged and untracked changes, not its own cache',()=>{
 const d=mkdtempSync(join(tmpdir(),'review-hash-'));try{
 const git=(...args)=>execFileSync('git',['-c','user.name=Test','-c','user.email=test@example.invalid',...args],{cwd:d});git('init','-q');writeFileSync(join(d,'a'),'one');git('add','a');git('commit','-qm','base');
 const a=reviewFingerprint(d);writeFileSync(join(d,'a'),'two');const b=reviewFingerprint(d);assert.notEqual(a,b);git('add','a');assert.notEqual(b,reviewFingerprint(d));
 const c=reviewFingerprint(d);writeFileSync(join(d,'new'),'new');assert.notEqual(c,reviewFingerprint(d));const e=reviewFingerprint(d);mkdirSync(join(d,'.cc-suite'));writeFileSync(join(d,'.cc-suite/stop-review-cache.json'),'cache');assert.equal(e,reviewFingerprint(d));writeFileSync(join(d,'.cc-suite/config.json'),'changed config');assert.notEqual(e,reviewFingerprint(d));
 }finally{rmSync(d,{recursive:true,force:true});}
});
