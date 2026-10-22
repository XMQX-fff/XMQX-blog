// ESM 解析钩子：把 'dompurify' 换成最小桩。
//
// mermaid 的解析路径（sanitizeText → removeScript → DOMPurify.sanitize）
// 需要一个 DOM。Node 里 dompurify 导出的只是工厂函数，直接调会抛
// "DOMPurify.addHook is not a function"。这个校验只关心图语法，
// HTML 净化那层用原样返回的桩足够。
const STUB = `
const stub = {
  isSupported: false,
  sanitize: (s) => s,
  addHook: () => {},
  removeHook: () => {},
  removeAllHooks: () => {},
  removeHooks: () => {},
  setConfig: () => {},
  clearConfig: () => {},
}
export default stub
`

export function resolve(specifier, context, next) {
  if (specifier === 'dompurify') {
    return {
      url: 'data:text/javascript;charset=utf-8,' + encodeURIComponent(STUB),
      shortCircuit: true,
    }
  }
  return next(specifier, context)
}
