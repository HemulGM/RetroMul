unit PC.Sound.OPL3;

interface

uses
  PC.Sound.OPL;

type
  // YMF262, eighteen channels, six optional four-operator pairs and stereo.
  // Reset starts in hardware-compatible OPL2 mode; register $105 enables OPL3.
  TOPL3 = class(TOPLSound)
  public
    constructor Create(Clock: Integer = 14318180; SampleRate: Integer = 44100);
  end;

implementation

constructor TOPL3.Create(Clock, SampleRate: Integer);
begin
  CreateChip(True, Clock, SampleRate);
end;

end.

