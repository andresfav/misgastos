import { useLayoutEffect, useRef, type ChangeEventHandler } from "react";

export function AutoGrowingNote({ value, onChange }: {
  value: string;
  onChange: ChangeEventHandler<HTMLTextAreaElement>;
}) {
  const ref = useRef<HTMLTextAreaElement>(null);
  useLayoutEffect(() => {
    const textarea = ref.current!;
    const resize = () => {
      const style = getComputedStyle(textarea);
      const border = parseFloat(style.borderTopWidth) + parseFloat(style.borderBottomWidth);
      textarea.style.height = "auto";
      textarea.style.height = `${Math.min(textarea.scrollHeight + border, parseFloat(style.maxHeight))}px`;
    };
    resize();
    let width = textarea.clientWidth;
    const observer = new ResizeObserver(() => {
      if (textarea.clientWidth !== width) {
        width = textarea.clientWidth;
        resize();
      }
    });
    observer.observe(textarea);
    return () => observer.disconnect();
  }, [value]);
  return <textarea ref={ref} className="auto-growing-note" rows={1} value={value} onChange={onChange} />;
}
