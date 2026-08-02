import * as fs from 'fs';
import * as path from 'path';

/**
 * L'hygiène de la frontière HTTP, tenue par un contrôle exécuté (règle 13).
 *
 * ── Pourquoi un test plutôt qu'une relecture ────────────────────────────────
 *
 * Les quatre règles vérifiées ici sont simples, connues, et **toutes les quatre
 * ont déjà été enfreintes** :
 *
 * - un `@Body()` typé en ligne échappe entièrement au `ValidationPipe`, qui ne
 *   valide que les classes décorées. Une entreprise a pu contester une remise
 *   avec un motif de longueur illimitée là où les autres personas sont bornés à
 *   500 caractères : le plafond n'était pas contourné, **il n'existait pas** ;
 * - un champ de DTO sans décorateur n'est pas validé, même si son type
 *   TypeScript paraît le contraindre — le type disparaît à la compilation ;
 * - un `@Param('id')` sans pipe part **interpolé dans une URL Fleetbase appelée
 *   avec le jeton de service** ;
 * - une expression régulière recopiée en clair diverge un jour de celle qui est
 *   nommée. Constaté : `register.dto.ts` réécrivait le motif d'identifiant
 *   Fleetbase employé six fois ailleurs.
 *
 * ⚠️ **Ce contrôle protège le code à venir, pas le code présent.** Le dépôt est
 * propre au 02/08/2026 ; ce qui manquait, c'est ce qui empêche la prochaine
 * route de rouvrir un de ces quatre trous. Un rangement sans garde n'est pas un
 * chantier, c'est un instantané.
 *
 * ── Ce que ce fichier NE remplace pas ───────────────────────────────────────
 *
 * Il lit la **forme** du code. Que la borne soit la bonne, que l'appartenance
 * soit vérifiée, qu'une route refuse ce qu'elle doit refuser — rien de tout
 * cela ne se voit ici. Ces questions ont leurs bancs (`test-frontiere-http.sh`,
 * `test-appartenance.sh`).
 */

const SRC = path.join(__dirname, '..');

function walk(dir: string, suffix: string): string[] {
  const out: string[] = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) out.push(...walk(full, suffix));
    else if (entry.name.endsWith(suffix)) out.push(full);
  }
  return out;
}

const read = (file: string) => fs.readFileSync(file, 'utf8');
const relative = (file: string) => path.relative(SRC, file).replace(/\\/g, '/');

// ── Les quatre détecteurs, purs et éprouvables séparément ────────────────────

/** Un `@Body()` doit être typé par une classe, jamais en ligne ni en `any`. */
export function bodiesWithoutDto(source: string): string[] {
  const bad: string[] = [];
  const re = /@Body\([^)]*\)\s*\w+\s*:\s*([^,)\n]+)/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(source))) {
    const type = m[1].trim();
    if (type.startsWith('{') || type === 'any' || /^(string|number|boolean|Record)/.test(type)) {
      bad.push(type);
    }
  }
  return bad;
}

/** Un `@Param('id')` doit traverser un pipe. */
export function paramsWithoutPipe(source: string): string[] {
  const bad: string[] = [];
  const re = /@Param\(\s*'([^']+)'\s*(,[^)]*)?\)/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(source))) {
    if (!m[2] || !/Pipe/.test(m[2])) bad.push(m[1]);
  }
  return bad;
}

/**
 * Un champ de DTO doit porter au moins un décorateur.
 *
 * ⚠️ **Trois versions ont été nécessaires**, et les deux premières ont annoncé
 * six champs nus qui ne l'étaient pas : elles s'arrêtaient sur le `})` de
 * fermeture d'un décorateur multi-ligne. On remonte donc jusqu'à la frontière
 * du champ précédent, sans essayer de reconnaître la forme des continuations —
 * une forme qu'on ne peut pas énumérer.
 */
export function fieldsWithoutDecorator(source: string): string[] {
  const lines = source.split('\n');
  const field = /^\s{2}([a-zA-Z_]\w*)[?!]?\s*:\s*[^=;{]+;\s*$/;
  const bad: string[] = [];
  lines.forEach((line, i) => {
    const m = field.exec(line);
    if (!m) return;
    for (let j = i - 1; j >= 0; j--) {
      const t = lines[j].trim();
      if (t.startsWith('@')) return;
      if (t.startsWith('export class') || t.startsWith('class ') || field.test(lines[j])) break;
    }
    bad.push(m[1]);
  });
  return bad;
}

/**
 * Une expression régulière écrite en clair là où un motif est nommé.
 *
 * On ne juge pas toutes les regex — seulement celles qui reproduisent un motif
 * partagé. Une regex propre à un champ (un format de téléphone local) reste
 * légitime à sa place.
 */
export const SHARED_PATTERNS: Record<string, RegExp> = {
  FLEETBASE_ID_PATTERN: /\/\^\[A-Za-z0-9_-\]\{1,64\}\$\//,
};

export function inlineCopiesOfSharedPatterns(source: string): string[] {
  return Object.entries(SHARED_PATTERNS)
    .filter(([, re]) => re.test(source))
    .map(([name]) => name);
}

// ── Le dépôt ─────────────────────────────────────────────────────────────────

describe('hygiène des DTO et des contrôleurs', () => {
  const controllers = walk(SRC, '.controller.ts');
  const dtos = walk(SRC, '.dto.ts');

  it('trouve bien des fichiers à examiner', () => {
    // ⚠️ Sans ce cas, un chemin cassé rendrait tous les autres verts : zéro
    // fichier lu, zéro défaut trouvé. « Rien à signaler » et « je n'ai rien
    // regardé » ne se disent pas pareil.
    expect(controllers.length).toBeGreaterThan(3);
    expect(dtos.length).toBeGreaterThan(8);
  });

  it('aucun @Body() typé en ligne, en any ou en primitif', () => {
    const faults = controllers
      .map((f) => ({ file: relative(f), bad: bodiesWithoutDto(read(f)) }))
      .filter((x) => x.bad.length);
    expect(faults).toEqual([]);
  });

  it('aucun @Param() sans pipe', () => {
    const faults = controllers
      .map((f) => ({ file: relative(f), bad: paramsWithoutPipe(read(f)) }))
      .filter((x) => x.bad.length);
    expect(faults).toEqual([]);
  });

  it('aucun champ de DTO sans décorateur de validation', () => {
    const faults = dtos
      .map((f) => ({ file: relative(f), bad: fieldsWithoutDecorator(read(f)) }))
      .filter((x) => x.bad.length);
    expect(faults).toEqual([]);
  });

  it('aucune recopie en clair d’un motif partagé', () => {
    const faults = [...dtos, ...controllers]
      .filter((f) => !f.includes('fleetbase-id.pipe'))
      .map((f) => ({ file: relative(f), bad: inlineCopiesOfSharedPatterns(read(f)) }))
      .filter((x) => x.bad.length);
    expect(faults).toEqual([]);
  });
});

// ── Ce que les détecteurs doivent REFUSER (règle 8) ──────────────────────────
//
// Un contrôle au vert n'a montré que sa capacité à dire oui. Autant de cas qui
// doivent échouer que de cas qui doivent passer — et ils sont écrits à partir
// du code réel qui a produit chaque défaut, pas inventés.
describe('les détecteurs savent refuser', () => {
  it('@Body en ligne, en any, en primitif', () => {
    expect(bodiesWithoutDto('@Body() dto: { reason?: string }')).toHaveLength(1);
    expect(bodiesWithoutDto('@Body() dto: any')).toHaveLength(1);
    expect(bodiesWithoutDto('@Body() n: number')).toHaveLength(1);
    expect(bodiesWithoutDto('@Body() dto: Record<string, any>')).toHaveLength(1);
  });

  it('mais accepte une classe décorée', () => {
    expect(bodiesWithoutDto('@Body() dto: DisputeRemittanceDto')).toEqual([]);
    expect(bodiesWithoutDto("@Body('x') dto: SaveAddressDto")).toEqual([]);
  });

  it('@Param sans pipe', () => {
    expect(paramsWithoutPipe("@Param('id') id: string")).toEqual(['id']);
    // Un second argument qui n'est pas un pipe ne compte pas.
    expect(paramsWithoutPipe("@Param('id', ParseIntPipe) id: number")).toEqual([]);
    expect(paramsWithoutPipe("@Param('id', FleetbaseIdPipe) id: string")).toEqual([]);
  });

  it('champ de DTO nu', () => {
    expect(fieldsWithoutDecorator('export class A {\n  nom: string;\n}')).toEqual(['nom']);
  });

  it('mais reconnaît un décorateur multi-ligne — le faux positif d’origine', () => {
    // ⚠️ Le cas exact sur lequel deux versions du détecteur se sont trompées.
    const src = [
      'export class A {',
      '  @Matches(FLEETBASE_ID_PATTERN, {',
      "    message: 'invalide',",
      '  })',
      '  uuid: string;',
      '}',
    ].join('\n');
    expect(fieldsWithoutDecorator(src)).toEqual([]);
  });

  it('recopie en clair d’un motif partagé', () => {
    expect(inlineCopiesOfSharedPatterns('@Matches(/^[A-Za-z0-9_-]{1,64}$/)'))
      .toEqual(['FLEETBASE_ID_PATTERN']);
    expect(inlineCopiesOfSharedPatterns('@Matches(FLEETBASE_ID_PATTERN)')).toEqual([]);
  });
});
