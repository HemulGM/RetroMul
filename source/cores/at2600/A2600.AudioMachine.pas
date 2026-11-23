unit A2600.AudioMachine;

interface

uses
  System.SysUtils, A2600.Console;

type
  // Sample-pull adapter over the shared Atari 2600 hardware.
  TAtari2600Audio = class
  private
    FConsole: TA2600Console;
  public
    constructor Create(const ROM: TBytes; PAL: Boolean = True);
    destructor Destroy; override;
    procedure Reset;
    procedure Sample(out Left, Right: SmallInt);
  end;

implementation

constructor TAtari2600Audio.Create(const ROM: TBytes; PAL: Boolean);
begin
  inherited Create;
  FConsole := TA2600Console.Create(ROM, PAL, '', False);
end;

destructor TAtari2600Audio.Destroy;
begin
  FConsole.Free;
  inherited;
end;

procedure TAtari2600Audio.Reset;
begin
  FConsole.Reset;
end;

procedure TAtari2600Audio.Sample(out Left, Right: SmallInt);
begin
  FConsole.Sample(Left, Right);
end;

end.

