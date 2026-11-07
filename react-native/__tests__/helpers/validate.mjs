// `node validate.mjs <schema> <definition>`: checks the JSON on stdin against a definition of a protocol schema.
import { validate } from '../../../protocol/validate.mjs';

const [schema, def] = process.argv.slice(2);
let text = '';
for await (const chunk of process.stdin) text += chunk;
const errors = validate(schema, JSON.parse(text), def);
if (errors.length) {
  console.error(errors.join('\n'));
  process.exit(1);
}
