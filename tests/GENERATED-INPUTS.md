# Deterministic generated input checks

Generator version 1 uses seed `0x5c018a73` for raster cases and decimal seed `1543604851` for JSON cases. Fast checks add 128 PNG and 64 GIF cases, plus 128 JSON cases under each supported PowerShell host. The extended tier selects 4,096 cases per category. Existing exhaustive regressions remain in place.

Run `npm run test:fast` for the raster fast tier, `tests/Test-GeneratedJson.ps1` in each host for JSON, or `npm run test:generated:extended` for both hosts and extended rasters. Generators and their runner are test resources, outside portable runtime packages.

The PNG generator defines pixels independently, packs samples and padding bits, and applies forward filters from the PNG definitions without production imports. Forty fixed controls cover all four indexed depths, five filters, and both interlace modes. Mutations combine raw identifiers, ordering, transparency, invalid palette indices, filter bytes, truncation, lengths, and checksums. Valid unknown ancillary chunks remain controls. GIF controls encode independently specified clear/pixel/end LZW codes and exact GIF87a/GIF89a headers.

Every raster case exercises both validators and bundled retrieval; representative categories also exercise indexing and prior-output preservation. Valid PNG retrieval must return exact original bytes. Invalid cases and GIFs must expose no image bytes, preserving the existing GIF retrieval restriction. JSON cases use independently specified object/non-object roots with nested arrays and values, exercise recovery readers, and preserve canonical files, backups, and pending evidence. The standalone release reader is additionally exercised under its intentional PowerShell 7 interface.

Unexpected failures retain generator version, seed, case number, input hash, bytes and diagnostics in the reported temporary evidence directory. Minimize a reproducible unexpected input into a permanent regression before correcting a confirmed defect. Passing parser agreement alone is insufficient; expected valid/invalid outcomes and pixels come from the generator specification and existing independently checked vectors.
