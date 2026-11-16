unit Audio.MP3.Frame;

{$POINTERMATH ON}

interface

uses
  System.SysUtils, System.Classes, Audio.MP3.Types, Audio.MP3.BitStream;

type
  TMP3FrameParser = class
  public
    // Sync to next frame header and parse it
    class function ParseHeader(Stream: TStream; out Header: TMP3FrameHeader): Boolean;

    // Parse side information using minimp3's L3_read_side_info logic
    // Returns main_data_begin, or -1 on error
    class function ParseSideInfo(BS: TMP3BitStream; const Header: TMP3FrameHeader; out SideInfo: TMP3SideInfo): Boolean;

    // Size of side info in bytes
    class function SideInfoSize(const Header: TMP3FrameHeader): Integer;
  end;

implementation

class function TMP3FrameParser.SideInfoSize(const Header: TMP3FrameHeader): Integer;
begin
  if HDR_TEST_MPEG1(Header.hdr) then
  begin
    if Header.Channels = 1 then
      Result := 17
    else
      Result := 32;
  end
  else
  begin
    if Header.Channels = 1 then
      Result := 9
    else
      Result := 17;
  end;
end;

class function TMP3FrameParser.ParseHeader(Stream: TStream; out Header: TMP3FrameHeader): Boolean;
var
  B0, B1, B2, B3: Byte;
  StreamPos: Int64;
  ha: array[0..3] of Byte;
  br, sr: Integer;
begin
  Result := False;
  FillChar(Header, SizeOf(Header), 0);

  while Stream.Position < Stream.Size - 4 do
  begin
    StreamPos := Stream.Position;
    if Stream.Read(B0, 1) < 1 then
      Exit;
    if B0 <> $FF then
      Continue;
    if Stream.Read(B1, 1) < 1 then
      Exit;

    // Check sync: 11 bits all set, or the 0xE2xx pattern for MPEG2.5
    if not (((B1 and $F0) = $F0) or ((B1 and $FE) = $E2)) then
    begin
      Stream.Position := StreamPos + 1;
      Continue;
    end;

    if Stream.Read(B2, 1) < 1 then
      Exit;
    if Stream.Read(B3, 1) < 1 then
      Exit;

    ha[0] := B0;
    ha[1] := B1;
    ha[2] := B2;
    ha[3] := B3;

    // Validate using minimp3 hdr_valid logic
    if (HDR_GET_LAYER(ha) = 0) or
      (HDR_GET_BITRATE(ha) = 15) or
      (HDR_GET_SAMPLE_RATE(ha) = 3) then
    begin
      Stream.Position := StreamPos + 1;
      Continue;
    end;

    // We only handle Layer 3 in this decoder
    if HDR_GET_LAYER(ha) <> 1 then  // layer=01 means layer3 in header encoding
    begin
      Stream.Position := StreamPos + 1;
      Continue;
    end;

    br := HDR_GET_BITRATE(ha);
    if br = 0 then  // free format not supported in simple mode
    begin
      Stream.Position := StreamPos + 1;
      Continue;
    end;

    sr := HDR_GET_SAMPLE_RATE(ha);

    Header.hdr[0] := B0;
    Header.hdr[1] := B1;
    Header.hdr[2] := B2;
    Header.hdr[3] := B3;

    if HDR_TEST_MPEG1(ha) then
      Header.Version := 3       // MPEG1
    else if (ha[1] shr 3) and 3 = 2 then
      Header.Version := 2       // MPEG2
    else
      Header.Version := 0;      // MPEG2.5
    Header.Layer := 3;
    Header.BitrateIndex := br;
    Header.SampleRateIndex := sr;
    if HDR_TEST_PADDING(ha) then
      Header.Padding := 1
    else
      Header.Padding := 0;
    Header.ChannelMode := TChannelMode(HDR_GET_STEREO_MODE(ha));
    Header.ModeExtension := HDR_GET_STEREO_MODE_EXT(ha);
    Header.Copyright := (B3 shr 3) and 1 = 1;
    Header.Original := (B3 shr 2) and 1 = 1;
    Header.Emphasis := B3 and 3;

    Header.Bitrate := hdr_bitrate_kbps(@Header.hdr[0]);
    Header.SampleRate := hdr_sample_rate_hz(@Header.hdr[0]);

    if HDR_IS_MONO(ha) then
      Header.Channels := 1
    else
      Header.Channels := 2;

    Header.FrameSize := hdr_frame_bytes(@Header.hdr[0], 0) + hdr_padding(@Header.hdr[0]);

    if Header.FrameSize < 21 then
    begin
      Stream.Position := StreamPos + 1;
      Continue;
    end;

    Result := True;
    Exit;
  end;
end;

class function TMP3FrameParser.ParseSideInfo(BS: TMP3BitStream; const Header: TMP3FrameHeader; out SideInfo: TMP3SideInfo): Boolean;
var
  G, Ch: Integer;
  GI: ^TGranuleInfo;
  tables: Cardinal;
  scfsi_bits: Cardinal;
  nch: Integer;
  ch0s, ch1s: Byte;
  isMP1: Boolean;
  nGranules: Integer;
begin
  Result := False;
  FillChar(SideInfo, SizeOf(SideInfo), 0);

  nch := Header.Channels;
  isMP1 := HDR_TEST_MPEG1(Header.hdr);
  if isMP1 then
    nGranules := 2
  else
    nGranules := 1;

  if isMP1 then
  begin
    // MPEG1 header bits: 9-bit main_data_begin, private bits, scfsi
    SideInfo.MainDataBegin := BS.ReadBits(9);

    if nch = 1 then
      SideInfo.PrivateBits := BS.ReadBits(5)
    else
      SideInfo.PrivateBits := BS.ReadBits(3);

    // scfsi: 4 bits per channel
    scfsi_bits := BS.ReadBits(4 * nch);

    if nch = 1 then
    begin
      SideInfo.Scfsi[0][0] := (scfsi_bits and 8) <> 0;
      SideInfo.Scfsi[0][1] := (scfsi_bits and 4) <> 0;
      SideInfo.Scfsi[0][2] := (scfsi_bits and 2) <> 0;
      SideInfo.Scfsi[0][3] := (scfsi_bits and 1) <> 0;
    end
    else
    begin
      ch0s := (scfsi_bits shr 4) and $F;
      ch1s := scfsi_bits and $F;
      SideInfo.Scfsi[0][0] := (ch0s and 8) <> 0;
      SideInfo.Scfsi[0][1] := (ch0s and 4) <> 0;
      SideInfo.Scfsi[0][2] := (ch0s and 2) <> 0;
      SideInfo.Scfsi[0][3] := (ch0s and 1) <> 0;
      SideInfo.Scfsi[1][0] := (ch1s and 8) <> 0;
      SideInfo.Scfsi[1][1] := (ch1s and 4) <> 0;
      SideInfo.Scfsi[1][2] := (ch1s and 2) <> 0;
      SideInfo.Scfsi[1][3] := (ch1s and 1) <> 0;
    end;
  end
  else
  begin
    // MPEG2/2.5: 8-bit main_data_begin, 1-2 private bits, no scfsi
    SideInfo.MainDataBegin := BS.ReadBits(8);
    if nch = 1 then
      BS.ReadBits(1)   // 1 private bit (discard)
    else
      BS.ReadBits(2);  // 2 private bits (discard)
    // Scfsi stays zeroed (already done by FillChar above)
  end;

  for G := 0 to nGranules - 1 do
  begin
    for Ch := 0 to nch - 1 do
    begin
      GI := @SideInfo.Granules[G][Ch];

      GI^.Part2_3_Length := BS.ReadBits(12);
      GI^.BigValues := BS.ReadBits(9);
      if GI^.BigValues > 288 then
        Exit;
      GI^.GlobalGain := BS.ReadBits(8);
      if isMP1 then
        GI^.ScalefacCompress := BS.ReadBits(4)  // MPEG1: 4 bits
      else
        GI^.ScalefacCompress := BS.ReadBits(9); // MPEG2: 9 bits

      if BS.ReadBits(1) = 1 then
      begin
        // window_switching_flag = 1
        GI^.BlockType := BS.ReadBits(2);
        if GI^.BlockType = 0 then
          Exit;  // invalid
        if BS.ReadBits(1) = 1 then
          GI^.MixedBlockFlag := True
        else
          GI^.MixedBlockFlag := False;
        GI^.WindowSwitchingFlag := True;

        // region counts fixed for window switching
        GI^.Region0Count := 7;
        GI^.Region1Count := 255;

        if GI^.BlockType = SHORT_BLOCK_TYPE then
        begin
          begin // Short blocks never reuse SCFSI, including mixed blocks.
            SideInfo.Scfsi[Ch][0] := False;
            SideInfo.Scfsi[Ch][1] := False;
            SideInfo.Scfsi[Ch][2] := False;
            SideInfo.Scfsi[Ch][3] := False;
          end;
          if not GI^.MixedBlockFlag then
            GI^.Region0Count := 8;
        end;

        // Read table_select for regions 0 and 1 (10 bits total)
        tables := BS.ReadBits(10);
        tables := tables shl 5;

        GI^.TableSelect[0] := (tables shr 10) and 31;
        GI^.TableSelect[1] := (tables shr 5) and 31;
        GI^.TableSelect[2] := 0;

        GI^.SubblockGain[0] := BS.ReadBits(3);
        GI^.SubblockGain[1] := BS.ReadBits(3);
        GI^.SubblockGain[2] := BS.ReadBits(3);
      end
      else
      begin
        GI^.WindowSwitchingFlag := False;
        GI^.BlockType := 0;
        GI^.MixedBlockFlag := False;

        tables := BS.ReadBits(15);
        GI^.TableSelect[0] := (tables shr 10) and 31;
        GI^.TableSelect[1] := (tables shr 5) and 31;
        GI^.TableSelect[2] := tables and 31;

        GI^.Region0Count := BS.ReadBits(4);
        GI^.Region1Count := BS.ReadBits(3);
      end;

      if isMP1 then
      begin
        // MPEG1: preflag is explicit bit in stream
        if BS.ReadBits(1) = 1 then
          GI^.Preflag := True
        else
          GI^.Preflag := False;
      end
      else
      begin
        // MPEG2: preflag derived from scalefac_compress
        GI^.Preflag := GI^.ScalefacCompress >= 500;
      end;
      GI^.ScalefacScale := BS.ReadBits(1);
      GI^.Count1TableSelect := BS.ReadBits(1);
    end;
  end;

  Result := True;
end;

end.

