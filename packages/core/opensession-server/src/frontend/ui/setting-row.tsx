import * as React from "react";
import {
  SETTING_GLYPH,
  SETTING_ROW,
  SETTING_ROW_PRESSABLE,
} from "../lib/setting-row-classes";
import { IconChevronDown } from "../components/icons";
import { cn } from "./cn";
import { Menu } from "./menu";
import { Switch } from "./switch";

/** The rows a settings popover is made of. The rule they follow, and why they
 *  wear a menu row rather than a field, is in `lib/setting-row-classes`. */
export interface SettingOption {
  value: string;
  label: string;
  icon?: React.ReactNode;
}

/** A setting whose control draws itself: a segmented control, a stepper, a
 *  pair of buttons. The row names it and pins it right. */
export function SettingRow({
  label,
  className,
  children,
}: {
  label: string;
  className?: string;
  children: React.ReactNode;
}) {
  return (
    <div className={cn(SETTING_ROW, className)}>
      <span className="shrink-0 text-dim">{label}</span>
      <span className="ml-auto flex min-w-0 items-center gap-2">
        {children}
      </span>
    </div>
  );
}

/** A setting that is on or off. The label is part of the target, so the whole
 *  row flips it. */
export function SwitchRow({
  label,
  checked,
  disabled,
  onCheckedChange,
}: {
  label: string;
  checked: boolean;
  disabled?: boolean;
  onCheckedChange: (checked: boolean) => void;
}) {
  return (
    <label
      className={cn(
        SETTING_ROW,
        disabled ? "cursor-default" : SETTING_ROW_PRESSABLE,
      )}
    >
      {/* A setting that cannot apply yet dims its name too: a live label
			    over a faded switch reads as a switch that failed to draw. */}
      <span className={cn("shrink-0", disabled ? "text-faint" : "text-dim")}>
        {label}
      </span>
      <Switch
        className="ml-auto"
        size="sm"
        checked={checked}
        disabled={disabled}
        onCheckedChange={onCheckedChange}
      />
    </label>
  );
}

/** The options behind a `ValueRow`, and behind a submenu asking the same
 *  question one level in. */
export function ValueOptions({
  value,
  options,
  onSelect,
}: {
  value: string;
  options: SettingOption[];
  onSelect: (value: string) => void;
}) {
  const glyphs = options.some((option) => option.icon);
  return (
    <Menu.RadioGroup
      value={value}
      onValueChange={(next) => onSelect(String(next))}
    >
      {options.map((option) => (
        // `closeOnClick`, because this list is a value picker: Base UI
        // leaves a radio item's menu open by default, which is right for a
        // menu you keep toggling things in and wrong for one answering a
        // single question.
        <Menu.RadioItem
          key={option.value}
          value={option.value}
          closeOnClick
          className="justify-between gap-3"
        >
          <span className="flex min-w-0 items-center gap-2">
            {glyphs && <span className={SETTING_GLYPH}>{option.icon}</span>}
            <span className="min-w-0 truncate">{option.label}</span>
          </span>
          <Menu.Check on={option.value === value} />
        </Menu.RadioItem>
      ))}
    </Menu.RadioGroup>
  );
}

/** A setting whose answers are too long to show at once: the row IS the
 *  control, holding the name, the answer in effect, and a chevron. */
export function ValueRow({
  label,
  value,
  options,
  onSelect,
  trailing,
  footer,
  className,
}: {
  label: string;
  value: string;
  options: SettingOption[];
  onSelect: (value: string) => void;
  /** A glyph after the value, for a second setting the value is read with
   *  rather than another value to pick: the direction an order runs in. */
  trailing?: React.ReactNode;
  /** Rows under the options, below a rule: a setting about the things the
   *  options name, rather than another one of them to pick. */
  footer?: React.ReactNode;
  className?: string;
}) {
  const current = options.find((option) => option.value === value);
  return (
    <Menu.Root>
      <Menu.Trigger
        className={cn(SETTING_ROW, SETTING_ROW_PRESSABLE, className)}
      >
        <span className="shrink-0 text-dim">{label}</span>
        <span className="ml-auto flex min-w-0 items-center gap-2 text-fg">
          {current?.icon && (
            <span className={SETTING_GLYPH}>{current.icon}</span>
          )}
          <span className="truncate">{current?.label ?? value}</span>
          {trailing}
          <IconChevronDown size={16} className="-mr-0.5 shrink-0 text-faint" />
        </span>
      </Menu.Trigger>
      <Menu.Popup align="end" sideOffset={6}>
        <ValueOptions value={value} options={options} onSelect={onSelect} />
        {footer && (
          <>
            <Menu.Separator />
            {footer}
          </>
        )}
      </Menu.Popup>
    </Menu.Root>
  );
}
