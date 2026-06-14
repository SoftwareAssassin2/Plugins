import { ApplicationInitStatus } from '@angular/core';
import { TestBed } from '@angular/core/testing';
import { provideHttpClientTesting, HttpTestingController } from '@angular/common/http/testing';
import { appConfig } from './app.config';
import { AppConfigService } from './core/app-config';

// App-consumption test for the REAL bootstrap wiring: it loads appConfig.providers
// verbatim (the same array main.ts bootstraps with) and overlays only HTTP testing.
// If app.config.ts ever drops the provideAppInitializer that fetches /config.json,
// this test fails — so the actual startup wiring is covered even though app.config.ts
// itself is excluded from line coverage (bootstrap-glue, per docs/tdd.md).
describe('WebApp startup wiring (appConfig)', () => {
  let httpMock: HttpTestingController;

  beforeEach(() => {
    TestBed.configureTestingModule({
      providers: [...appConfig.providers, provideHttpClientTesting()],
    });
    httpMock = TestBed.inject(HttpTestingController);
  });

  afterEach(() => httpMock.verify());

  it('fetches /config.json during initialization and populates AppConfigService', async () => {
    const ready = TestBed.inject(ApplicationInitStatus).donePromise;
    httpMock
      .expectOne('/config.json')
      .flush({ realmUrl: 'http://127.0.0.1:8080/realms/demo', clientId: 'webapp' });
    await ready;
    expect(TestBed.inject(AppConfigService).get().clientId).toBe('webapp');
  });
});
