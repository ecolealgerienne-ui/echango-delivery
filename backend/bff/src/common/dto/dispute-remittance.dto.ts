import { IsOptional, IsString, MaxLength } from 'class-validator';

/**
 * Motif d'une contestation de remise, quel que soit le persona.
 *
 * ── Pourquoi un seul DTO pour trois routes ────────────────────────────────
 *
 * Les trois personas contestent la même chose — « je n'ai pas reçu cette
 * somme » — sur trois routes distinctes (`transporteur/caisse`,
 * `commercant/encaissements`, `flotte/caisse`). Le corps, lui, est le même : un
 * motif facultatif. Règle 5 : si la contrainte change, elle doit changer pour
 * les trois, donc elle vit à un seul endroit.
 *
 * ⚠️ **Ce n'était pas un risque théorique, c'était déjà un trou.** Les deux
 * premières routes portaient chacune leur copie — identiques caractère pour
 * caractère — et la troisième **n'avait aucun DTO** : elle annotait son corps
 * par un type en ligne, `@Body() dto: { reason?: string }`. Or le
 * `ValidationPipe` de `main.ts` ne valide que les classes décorées : sans
 * métadonnées, il laisse passer le corps tel quel.
 *
 * Conséquence concrète : une entreprise de transport pouvait contester avec un
 * motif de **longueur illimitée**, et d'un type quelconque, là où un
 * transporteur et un commerçant sont bornés à 500 caractères de texte. Le
 * plafond n'était pas contourné, il n'existait simplement pas sur ce chemin.
 *
 * Trouvé en comparant les corps de fonction du client HTTP, où la variante
 * flotte sérialisait aussi `{'reason': null}` là où les deux autres omettaient
 * la clé — la divergence de surface qui a mené à la divergence de fond.
 */
export class DisputeRemittanceDto {
  @IsOptional()
  @IsString()
  @MaxLength(500)
  reason?: string;
}
