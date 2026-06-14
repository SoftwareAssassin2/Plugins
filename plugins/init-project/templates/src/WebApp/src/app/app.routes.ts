import { Routes } from '@angular/router';
import { Home } from './home/home';

// Path-based routing. The S3/CloudFront static-hosting fallback (error document
// -> /index.html) lets these client-side routes deep-link. See docs/front-end.md.
export const routes: Routes = [{ path: '', component: Home }];
