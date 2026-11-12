// swift-tools-version:6.0
import PackageDescription
let package=Package(name:"FindDuckOil",platforms:[.macOS(.v14)],products:[.executable(name:"SMBSearch",targets:["FindDuck"])],targets:[
 .target(name:"COilFind",path:"Vendor/OilFind/Sources/COilFind",publicHeadersPath:"include"),
 .target(name:"OilFindCore",dependencies:["COilFind"],path:"Vendor/OilFind/Sources/OilFindCore",swiftSettings:[.swiftLanguageMode(.v5)]),
 .executableTarget(name:"FindDuck",dependencies:["OilFindCore"],path:"Sources/FindDuck",swiftSettings:[.swiftLanguageMode(.v6),.unsafeFlags(["-warnings-as-errors"])],linkerSettings:[.linkedFramework("AppKit"),.linkedFramework("SwiftUI"),.linkedFramework("Carbon"),.linkedFramework("CoreServices")]),
 .testTarget(name:"OilFindCoreTests",dependencies:["OilFindCore","COilFind"],path:"Vendor/OilFind/Tests/OilFindCoreTests",swiftSettings:[.swiftLanguageMode(.v5)]),
 .testTarget(name:"FindDuckCoreTests",dependencies:["FindDuck","OilFindCore"],path:"Tests/FindDuckCoreTests",resources:[.copy("Fixtures")],swiftSettings:[.swiftLanguageMode(.v6)])
])
