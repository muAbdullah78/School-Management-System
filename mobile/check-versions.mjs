#!/usr/bin/env node
// Two things that must not drift in the Android app, checked before every build.
//
// 1. CAPACITOR ON BOTH SIDES OF THE BRIDGE. The JavaScript half of each plugin
//    is bundled into the web app (web/package.json) and the native half is
//    built from mobile/package.json. Two different versions of one plugin can
//    disagree about a method's name or its answer, and that shows up on a
//    phone as a button that does nothing. So every @capacitor package the web
//    app uses must be pinned here, exactly, to the same version.
//
// 2. THE PACKAGE NAME. Google Play ties the app to it for ever: once an upload
//    has used it, a different one is a different app with no users, no
//    reviews and no updates. It is written in three places, and all three must
//    agree with the one below.
import { readFileSync } from 'node:fs'

const PACKAGE = 'site.theschoolmanager.app'

const read = (p) => readFileSync(new URL(p, import.meta.url), 'utf8')
const web = JSON.parse(read('../web/package.json'))
const mobile = JSON.parse(read('./package.json'))
const pins = (pkg) => ({ ...pkg.dependencies, ...pkg.devDependencies })
const webPins = pins(web)
const mobilePins = pins(mobile)

const problems = []
const exact = /^\d+\.\d+\.\d+$/

for (const [name, version] of Object.entries(webPins)) {
  if (!name.startsWith('@capacitor/')) continue
  if (!exact.test(version)) problems.push(`web/package.json pins ${name} to "${version}", not an exact version`)
  if (mobilePins[name] !== version) {
    problems.push(`${name}: web/package.json has ${version}, mobile/package.json has ${mobilePins[name] ?? 'nothing'}`)
  }
}
for (const [name, version] of Object.entries(mobilePins)) {
  if (name.startsWith('@capacitor/') && !exact.test(version)) {
    problems.push(`mobile/package.json pins ${name} to "${version}", not an exact version`)
  }
}
const core = mobilePins['@capacitor/core']
for (const twin of ['@capacitor/android', '@capacitor/cli']) {
  if (mobilePins[twin] !== core) problems.push(`${twin} is ${mobilePins[twin]}, @capacitor/core is ${core}: they ship together`)
}

const config = JSON.parse(read('./capacitor.config.json'))
if (config.appId !== PACKAGE) problems.push(`capacitor.config.json appId is ${config.appId}, not ${PACKAGE}`)
const gradle = read('./android/app/build.gradle')
for (const [what, re] of [['namespace', /namespace\s*=\s*"([^"]+)"/], ['applicationId', /applicationId\s+"([^"]+)"/]]) {
  const found = gradle.match(re)?.[1]
  if (found !== PACKAGE) problems.push(`android/app/build.gradle ${what} is ${found ?? 'missing'}, not ${PACKAGE}`)
}

if (problems.length) {
  for (const p of problems) console.error(`::error::${p}`)
  process.exit(1)
}
const shared = Object.keys(webPins).filter((n) => n.startsWith('@capacitor/')).length
console.log(`mobile: ${shared} Capacitor packages pinned alike in web/ and mobile/, package name ${PACKAGE} in all three places`)
