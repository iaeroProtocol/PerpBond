"use client";
import ClaimCard from "@/components/ClaimCard";
import ToggleAutoCompound from "@/components/ToggleAutoCompound";
export default function AccountPage(){
  return (
    <div className="grid gap-4">
      <ClaimCard/>
      <ToggleAutoCompound/>
    </div>
  );
}

