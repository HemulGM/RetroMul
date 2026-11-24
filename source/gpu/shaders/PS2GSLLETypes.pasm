type
  TPS2DrawWords = array[0..383] of Cardinal;
  TPS2Draw = record
    P: TPS2DrawWords;
  end;

  TPS2PixelContext = record
    DrawIndex: Cardinal;
    PixelCache, FrameLoaded, DepthLoaded, FrameDirty, DepthDirty, Frame16, Depth16: Boolean;
    CachedFrame, CachedDepth, CachedFA, CachedZA: Cardinal;
  end;

  // Scalar bounds preserve the host's exact 24/48-byte push ranges.
  TPS2SpritePush = record
    X0, Y0, X1, Y1: Integer;
    Slot, Mode: Cardinal;
  end;
  TPS2TrianglePush = record
    X0, Y0, X1, Y1: Integer;
    Slot, Mode, TileBase, EntryBase, ResultBase, Count, Width, MaskBase: Cardinal;
  end;
