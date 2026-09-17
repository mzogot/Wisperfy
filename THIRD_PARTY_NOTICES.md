# Third-party notices

Wisperfy is MIT licensed (see `LICENSE`). It links and redistributes the following
third-party software, and downloads one model at runtime.

## FluidAudio

Bundled in the app binary. Copyright FluidInference contributors.
Licensed under the Apache License, Version 2.0. Source and license:
https://github.com/FluidInference/FluidAudio

You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0.
Unless required by applicable law or agreed to in writing, software distributed under
the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
KIND, either express or implied.

## NVIDIA Parakeet TDT 0.6B v3 (CoreML conversion)

Not bundled. Downloaded once on first use by FluidAudio into
`~/Library/Application Support/FluidAudio/Models/` from
https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml.
The original model by NVIDIA is released under CC-BY-4.0:
https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3

## Apple frameworks

Speech (`SpeechAnalyzer`), Foundation Models, AVFoundation and CoreML are part of macOS
and are used under Apple's SDK license terms.
