import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
await runConnectionTests()
await runManagerTests()
await runRelayTests()
await runExtraPhoneTests()
finish()
