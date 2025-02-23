- `DLGINCLUDE` resources are excluded from the COFF object file, but if they have a string ID, the name string is still written to the Resource Directory Strings, even though it is orphaned (not referenced by anything).
- cvtres.exe writes 0 as the string table length, which goes against the spec
- cvtres.exe writes a non-zero value to the 'pointer to relocations' field even if there are no relocations
- @comp.id symbol
- /FOLDDUPS writes orphaned duplicate data if the first resource has data that is the same as another resource
- ARM -> ARMNT
- Potential symbol name overlap when offset takes > 6 hex digits

See:
- CoffFixups in test/utils.zig
- writeRandomValidResource in test/utils.zig
- have_written_a_non_zero_data_resource in fuzzy_cvtres.zig