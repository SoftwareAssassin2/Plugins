import { inject, Injectable } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { firstValueFrom } from 'rxjs';

/**
 * Non-secret public runtime config for this SPA. It is fetched at runtime from
 * `/config.json` (served from the SPA's `public/` dir), NOT baked into the bundle
 * at build time — so a fresh `config.json` can be dropped beside `dist/` per
 * environment without rebuilding. Only NON-secret values live here (no client
 * secrets ever reach a static bundle). See docs/front-end.md + docs/keycloak.md.
 */
export interface AppConfig {
  /** Keycloak realm URL the SPA authenticates against (public). */
  realmUrl: string;
  /** Public OIDC client id for this SPA (public clients carry no secret). */
  clientId: string;
}

@Injectable({ providedIn: 'root' })
export class AppConfigService {
  private readonly http = inject(HttpClient);
  private config: AppConfig | null = null;

  /** Fetch and cache the public runtime config. Call once during app startup. */
  async load(): Promise<AppConfig> {
    this.config = await firstValueFrom(this.http.get<AppConfig>('/config.json'));
    return this.config;
  }

  /** The loaded config. Throws if accessed before `load()` resolves. */
  get(): AppConfig {
    if (!this.config) {
      throw new Error('AppConfig not loaded — call load() during app initialization.');
    }
    return this.config;
  }
}
