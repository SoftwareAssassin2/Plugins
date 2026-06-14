import { TestBed } from '@angular/core/testing';
import { Home } from './home';

describe('Home', () => {
  beforeEach(async () => {
    await TestBed.configureTestingModule({ imports: [Home] }).compileComponents();
  });

  it('renders the marketing landing copy', () => {
    const fixture = TestBed.createComponent(Home);
    fixture.detectChanges();
    const el = fixture.nativeElement as HTMLElement;
    expect(el.querySelector('.home')?.textContent).toContain('__SCAFFOLD_PROJECT_DESCRIPTION__');
  });
});
