import { extractWithStub } from './stub';
import { extractWithClaude } from './claude';

/**
 * Chooses the extraction provider.
 *
 * Defaults to the stub so that a fresh deployment cannot accidentally send
 * client documents to a third party before anyone has decided it should.
 * Switching provider is one environment variable and touches nothing
 * downstream — everything after this point works from the same return
 * shape regardless of what read the document.
 */
export function currentProvider() {
  return (process.env.EXTRACTION_PROVIDER || 'stub').toLowerCase();
}

export async function extractInvoice(input) {
  switch (currentProvider()) {
    case 'claude':
      return extractWithClaude(input);
    case 'stub':
    default:
      return extractWithStub(input);
  }
}
