import { Route, Routes } from "react-router-dom";

import { Toaster } from "@/components/ui/toaster";
import LoginPage from "@/features/auth/LoginPage";
import { RequireAuth } from "@/features/auth/RequireAuth";
import CardEditor from "@/features/cards/CardEditor";
import DeckDetailPage from "@/features/decks/DeckDetailPage";
import DeckListPage from "@/features/decks/DeckListPage";
import TrashView from "@/features/decks/TrashView";

/**
 * M1 web app router. Public /login; everything else behind <RequireAuth>.
 */
export default function App() {
  return (
    <>
      <Routes>
        <Route path="/login" element={<LoginPage />} />
        <Route element={<RequireAuth />}>
          <Route index element={<DeckListPage />} />
          <Route path="/trash" element={<TrashView />} />
          <Route path="/decks/:id" element={<DeckDetailPage />} />
          <Route
            path="/decks/:deckId/cards/new"
            element={<CardEditor />}
          />
          <Route
            path="/decks/:deckId/cards/:cardId"
            element={<CardEditor />}
          />
        </Route>
      </Routes>
      <Toaster />
    </>
  );
}
