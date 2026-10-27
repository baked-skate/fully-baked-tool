// Adds every baked. package on Thunderstore that modlist.json doesn't list yet. sync.yml runs it.
import { readFileSync, writeFileSync } from 'node:fs';

const response = await fetch('https://thunderstore.io/c/reskate/api/v1/package/');
if (!response.ok) throw new Error(`Thunderstore answered ${response.status}`);
const listing = await response.json();
const list = JSON.parse(readFileSync('modlist.json', 'utf8'));
const added = listing
    .filter((p) => p.owner === 'baked' && !p.is_deprecated && !p.has_nsfw_content)
    .map((p) => p.full_name)
    .filter((name) => !list.baked.includes(name));
if (added.length) {
    list.baked.push(...added);
    writeFileSync('modlist.json', JSON.stringify(list, null, 2) + '\n');
}
console.log(added.length ? `Added ${added.join(', ')}` : 'Nothing new.');
