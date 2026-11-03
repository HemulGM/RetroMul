unit A5200.CPU;

interface

uses
  C64.CPU, Core.Snapshots;

type
  // Sally uses the NMOS instruction engine; ANTIC stalls its bus externally.
  TCPU5200 = class(TCPU6510)
  public
    procedure SerializeState(State: TStateArchive); reintroduce;
  end;

implementation

uses
  System.Classes, NES.State;

procedure TCPU5200.SerializeState(State: TStateArchive);
begin
  // Retain the existing CPU snapshot representation without exposing NES
  // archive details to the console or to clients of the Atari core.
  var Memory := TMemoryStream.Create;
  try
    var Archive := TNesStateArchive.Create(Memory, False, 10);
    try
      inherited SerializeState(Archive);
    finally
      Archive.Free;
    end;
    State.Field(Memory.Memory^, Memory.Size);
    if State.Loading then
    begin
      Memory.Position := 0;
      Archive := TNesStateArchive.Create(Memory, True, 10);
      try
        inherited SerializeState(Archive);
      finally
        Archive.Free;
      end;
    end;
  finally
    Memory.Free;
  end;
end;

end.
