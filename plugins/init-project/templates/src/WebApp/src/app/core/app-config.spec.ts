import { TestBed } from '@angular/core/testing';
import { HttpTestingController, provideHttpClientTesting } from '@angular/common/http/testing';
import { provideHttpClient } from '@angular/common/http';
import { AppConfigService, AppConfig } from './app-config';

describe('AppConfigService', () => {
  let service: AppConfigService;
  let httpMock: HttpTestingController;
  const sample: AppConfig = {
    realmUrl: 'http://127.0.0.1:8080/realms/demo',
    clientId: 'webapp',
  };

  beforeEach(() => {
    TestBed.configureTestingModule({
      providers: [provideHttpClient(), provideHttpClientTesting()],
    });
    service = TestBed.inject(AppConfigService);
    httpMock = TestBed.inject(HttpTestingController);
  });

  afterEach(() => httpMock.verify());

  it('throws when get() is called before load()', () => {
    expect(() => service.get()).toThrow(/not loaded/);
  });

  it('fetches /config.json and caches it', async () => {
    const promise = service.load();
    httpMock.expectOne('/config.json').flush(sample);
    await expect(promise).resolves.toEqual(sample);
    expect(service.get()).toEqual(sample);
  });
});
