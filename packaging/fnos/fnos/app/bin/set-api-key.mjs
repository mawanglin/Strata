// 保存 API Key 的 SHA-256（明文从不落盘）。用法：
//   node set-api-key.mjs 文件            Key 从标准输入读（至少 16 位，只能是字母、数字、- 和 _）
//   node set-api-key.mjs 文件 --clear    关闭 API Key 访问（删除文件）
// Key 是用户自己定的长随机串，不是口令，所以用 SHA-256 而不是慢哈希：代理每个 API 请求都要校验，慢哈希会拖慢每次调用。
import { createHash } from 'node:crypto';
import { chmodSync, renameSync, rmSync, writeFileSync } from 'node:fs';

const [, , file, flag] = process.argv;
if (!file) { console.error('usage: set-api-key.mjs FILE [--clear]  (key on stdin)'); process.exit(2); }
if (flag === '--clear') { rmSync(file, { force: true }); process.exit(0); }

let input = '';
for await (const chunk of process.stdin) input += chunk;
const key = input.split('\n')[0].replace(/\r$/, '');
if (!/^[A-Za-z0-9_-]{16,128}$/.test(key)) { console.error('the API key must be 16-128 characters: letters, digits, - and _'); process.exit(1); }

const body = JSON.stringify({ sha256: createHash('sha256').update(key).digest('hex') }, null, 2) + '\n';
writeFileSync(`${file}.tmp`, body, { mode: 0o600 });
chmodSync(`${file}.tmp`, 0o600);
renameSync(`${file}.tmp`, file);
