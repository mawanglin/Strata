// 把访问密码存成 scrypt 哈希（明文从不落盘）。用法：node set-password.mjs 用户名 文件   （密码从标准输入读）
import { randomBytes, scryptSync } from 'node:crypto';
import { chmodSync, renameSync, writeFileSync } from 'node:fs';

const [, , user, file] = process.argv;
if (!user || !file) { console.error('usage: set-password.mjs USER FILE (password on stdin)'); process.exit(2); }

let input = '';
for await (const chunk of process.stdin) input += chunk;
const password = input.split('\n')[0].replace(/\r$/, '');
if (!password) { console.error('empty password'); process.exit(1); }

const salt = randomBytes(16);
const params = { N: 16384, r: 8, p: 1, keylen: 64 };
const hash = scryptSync(password, salt, params.keylen, { N: params.N, r: params.r, p: params.p });
const body = JSON.stringify({ user, salt: salt.toString('hex'), hash: hash.toString('hex'), params }, null, 2) + '\n';
writeFileSync(`${file}.tmp`, body, { mode: 0o600 });
chmodSync(`${file}.tmp`, 0o600);
renameSync(`${file}.tmp`, file);
