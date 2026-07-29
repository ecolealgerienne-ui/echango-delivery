import { BadRequestException, ValidationError } from '@nestjs/common';
import { ErrorCode } from './error-codes';

/**
 * Fabrique l'exception envoyée par `ValidationPipe` quand un DTO échoue.
 *
 * ── Le trou que ça comble ────────────────────────────────────────────────
 *
 * Sans `exceptionFactory`, `ValidationPipe` construit lui-même un
 * `BadRequestException` dont le message est la liste des contraintes
 * `class-validator`, toujours en anglais (« price must be a positive
 * number ») et sans `code` — invisible pour `HttpExceptionFilter`, qui ne
 * relaie que ce qui est présent dans le corps de l'exception. C'était le
 * seul point d'entrée HTTP du BFF encore hors du registre après la
 * conversion des 122 exceptions métier.
 *
 * ── Un seul code pour tous les champs ────────────────────────────────────
 *
 * `validation.failed` ne distingue pas *quel* champ a échoué : le
 * traducteur client affiche un message générique (« Certaines informations
 * sont invalides »), et les noms de champs — jamais traduits, puisqu'ils
 * viennent de `class-validator` — restent en anglais dans `fields`, à
 * l'usage du développeur qui lit les logs ou le réseau, pas de l'écran.
 */
function collectFields(errors: ValidationError[], prefix = ''): string[] {
  return errors.flatMap((error) => {
    const path = prefix ? `${prefix}.${error.property}` : error.property;
    if (error.children?.length) {
      return collectFields(error.children, path);
    }
    return [path];
  });
}

export function validationExceptionFactory(errors: ValidationError[]): BadRequestException {
  const fields = collectFields(errors);
  return new BadRequestException({
    code: ErrorCode.VALIDATION_FAILED,
    message: `Données invalides : ${fields.join(', ')}`,
    fields,
  });
}
