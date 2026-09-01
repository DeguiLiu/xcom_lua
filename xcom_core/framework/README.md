# XCOM C++ Frameworks

This directory contains reusable, project-owned C++ frameworks.  It is kept
separate from `../src`: that tree implements XCOM's ABI, serial backend, file
writer and product-specific Active Objects.

`coact/` is the only event runtime used by XCOM.  Its fixed pools, bounded
queues, Dispatcher and HSM are framework code; the XCOM Windows PAL adapter is
compiled by the product core from `../src/runtime` and implements coact's PAL
contract.  Keeping the two boundaries explicit prevents a product helper from
becoming a second scheduler or queue implementation.

The complete coact source, tests and design material remain together so changes
to its concurrency primitives can be reviewed and tested at the framework
boundary.  XCOM includes only `coact/include` and does not add coact's standalone
test or example CMake project to the product build.
