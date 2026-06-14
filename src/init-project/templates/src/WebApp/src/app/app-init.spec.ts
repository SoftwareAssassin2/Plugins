import { ApplicationInitStatus, inject, provideAppInitializer } from '@angular/core';
import { TestBed } from '@angular/core/testing';
import { provideHttpClient } from '@angular/common/http';
import { HttpTestingController, provideHttpClientTesting } from '@angular/common/http/testing';
import { AppConfigService } from './core/app-config';

// App-consumption test: proves the bootstrap initializer (wired in app.config.ts)
// actually fetches the stamped public /config.json at startup and populates
// AppConfigService for the rest of the app. Mirrors the provideAppInitializer
// wiring in app.config.ts (kept out of this test so the assertion is meaningful).
describe('WebApp startup config initializer', () => {
  let httpMock: HttpTestingController;

  beforeEach(() => {
    TestBed.configureTestingModule({
      providers: [
        provideHttpClient(),
        provideHttpClientTesting(),
        provideAppInitializer(() => inject(AppConfigService).load()),
      ],
    });
    httpMock = TestBed.inject(HttpTestingController);
  });

  afterEach(() => httpMock.verify());

  it('fetches /config.json during app initialization and populates AppConfigService', async () => {
    const ready = TestBed.inject(ApplicationInitStatus).donePromise;
    const req = httpMock.expectOne('/config.json');
    req.flush({ realmUrl: 'http://127.0.0.1:8080/realms/demo', clientId: 'webapp' });
    await ready;
    expect(TestBed.inject(AppConfigService).get().clientId).toBe('webapp');
  });
});
