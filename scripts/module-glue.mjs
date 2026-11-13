// Writes what Exact's own build compiles beside an app's native module, for the shell's
// ExactModules framework (shell/project.yml): Exact's module seam, and the glue it generates for
// an app with a module of its own and no packages. An embed build (`ios --embed`) leaves this out,
// so the shell builds the framework Exact would have built, from the same sources.
//   bun scripts/module-glue.mjs <exact checkout> <out dir>
import { copyFileSync, mkdirSync, readFileSync, rmSync } from 'node:fs';
import { basename, resolve } from 'node:path';

const [exact, out] = process.argv.slice(2);
const { composedModule, moduleSeam } = await import(resolve(exact, 'host/apple/compose.mjs'));
const { writeDataKeys } = await import(resolve(exact, 'host/apple/data-keys.mjs'));
const app = resolve(import.meta.dir, '../app');
rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true });
for (const file of moduleSeam(resolve, exact)) copyFileSync(file, resolve(out, basename(file)));
await Bun.write(resolve(out, 'ExactComposed.swift'), composedModule([], true));
writeDataKeys({ dir: app, manifest: JSON.parse(readFileSync(resolve(app, 'app.json'), 'utf8')) }, resolve(out, 'ExactDataKeys.swift'), 'ios');
