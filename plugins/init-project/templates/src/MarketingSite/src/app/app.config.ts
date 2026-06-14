import {
  ApplicationConfig,
  inject,
  provideAppInitializer,
  provideBrowserGlobalErrorListeners,
  provideZonelessChangeDetection,
} from '@angular/core';
import { provideRouter } from '@angular/router';
import { provideHttpClient } from '@angular/common/http';

import { routes } from './app.routes';
import { AppConfigService } from './core/app-config';

export const appConfig: ApplicationConfig = {
  providers: [
    provideBrowserGlobalErrorListeners(),
    provideZonelessChangeDetection(),
    provideRouter(routes),
    provideHttpClient(),
    // Fetch the non-secret public runtime config (/config.json) before the app
    // renders, so AppConfigService.get() is populated app-wide. See docs/front-end.md.
    provideAppInitializer(() => inject(AppConfigService).load()),
  ],
};
