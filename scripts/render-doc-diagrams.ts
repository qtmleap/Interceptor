import { resolve } from 'node:path';
import { renderPluginHooks } from '../docs/diagrams/plugin-hooks';

const root = resolve(import.meta.dir, '..');
for (const theme of ['light', 'dark'] as const) {
    await Bun.write(
        resolve(root, `docs/site/public/diagrams/plugin-hooks-${theme}.svg`),
        renderPluginHooks(theme),
    );
}
