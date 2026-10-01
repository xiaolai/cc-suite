import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { readFileSync, readlinkSync, lstatSync } from 'node:fs';
import { join } from 'node:path';
// Cache only exact reviewed content. A failure to enumerate never becomes a pass.
export function reviewFingerprint(cwd) {
 const git = args => execFileSync('git', args, {cwd,timeout:5000,maxBuffer:16*1024*1024});
 const hash=createHash('sha256');
 git(['rev-parse','--show-toplevel']);
 let head; try { head=git(['rev-parse','--verify','HEAD']); } catch { head=null; }
 hash.update(head || 'unborn'); hash.update(git(['diff', ...(head ? ['HEAD'] : []), '--binary','--no-ext-diff']));
 hash.update(git(['diff','--cached','--binary','--no-ext-diff']));
 for(const file of git(['ls-files','--others','--exclude-standard','-z']).toString().split('\0').filter(Boolean).sort()) {
  if(file === '.cc-suite/stop-review-cache.json') continue;
  hash.update(file);hash.update('\0'); const p=join(cwd,file); const stat=lstatSync(p);
  hash.update(String(stat.mode));hash.update(stat.isSymbolicLink()?readlinkSync(p):readFileSync(p));
 }
 return hash.digest('hex');
}
