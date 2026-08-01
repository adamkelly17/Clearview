import { requireOrg } from '@/lib/org';
import { currentProvider } from '@/lib/extraction';
import UploadForm from './UploadForm';

export const dynamic = 'force-dynamic';

export default async function CaptureUploadPage() {
  const { org } = await requireOrg();

  return (
    <div className="page">
      <div className="page-head">
        <div>
          <h1>Capture invoices</h1>
          <p>
            Upload supplier invoices and they will be read for you. Nothing
            posts until you have checked it.
          </p>
        </div>
      </div>

      <UploadForm orgId={org.id} provider={currentProvider()} />
    </div>
  );
}
